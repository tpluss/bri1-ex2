#coding: utf-8

require 'csv'
require 'digest'
require 'mechanize'

# Парсер каталога продукции сайта http://piknikvdom.ru
# Записывает заданное количество товаров в файл и подсчитывает статистику.
# Если все загруженные товары находятся в одной категории - добирает столько же.
#
# Разделителем CSV-файла является знак \t.
# Формат каталога:
#   Раздел | Подраздел | Наименование | Адрес карточки | Адрес картинки | Хэш
class PiknikParser

  MAIN_URL = 'http://www.piknikvdom.ru'
  PRODUCTS_URL = MAIN_URL + '/products'

  SECTBLOCK_SEL = 'div.section'
  SECTLINK_SEL = 'span.h3 > a.category-image'
  SUBSECT_SEL = 'p.categories-wrap > span > a'
  GOODSCARD_SEL = 'a.product-image'
  NEXTPAGE_SEL = 'a.pager-next'

  CSV_SEP = "\t"
  CAT_PATH = './catalog.txt'
  IMG_PATH  = './img'

  def initialize(path=nil, sep=nil, img_dir=nil)
    @path ||= CAT_PATH
    @sep ||= CSV_SEP

    @img_dir ||= IMG_PATH
    Dir.mkdir(@img_dir) unless Dir.exists?(@img_dir)

    @catalog_file = CSV.open(@path, 'a+', {:col_sep => @sep})

    # Чтобы не дёргать каждый раз файл, создадим массив хэшей, который будет
    # индикатором наличия объекта в каталоге.
    @saved = @catalog_file.readlines.collect{|r| r[5]}

    @goods_qnt = 50
    #return    
    @parsed = 0

    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = 'Windows Chrome'
    catalog_page = @mechanize.get(PRODUCTS_URL)
    catalog_page.search(SECTBLOCK_SEL).each do |sect_block|
      sect_title = sect_block.at(SECTLINK_SEL).attributes['title'].to_s
      #puts "Works on #{ sect_title }"

      sect_block.search(SUBSECT_SEL).each do |subsect_url|
        #puts "  Parse #{ subsect_url.text }"
        href = subsect_url.attributes['href']
        # Хорошо бы переделать на итератор, типа yield в питоне, который бы брал
        # по товару, если не достиг лимита. Тогда бы это позволило забирать сюда
        # данные по товару, не передавать sect, subsect и сохранять прямо здесь.
        return if self.parse_subsect(@mechanize.get(href), sect_title, subsect_url.text) == 'break'
      end
    end

    self.stat
  end

  def parse_subsect(subsect_page, sect, subsect)
    subsect_page.search(GOODSCARD_SEL).each do |goods_link|
      href = goods_link.attributes['href'].to_s
      name = goods_link.at('img').attributes['alt'].to_s
      # FIX: переход в карточку товара с последующим дёрганьем по css-селектору.
      img_url = goods_link.attributes['style'].value.sub('background: url(', '')\
        .sub(') no-repeat center center', '').sub('/images/no_photo_2.png', '')

      hash = Digest::SHA256.hexdigest(sect + subsect + name)
      next if @saved.index(hash)
      @catalog_file << [sect, subsect, name, href, img_url, hash]
      #puts "    #{ name }"

      unless img_url.empty?
        img_path = "#{ @img_dir }/#{ hash }#{ File.extname(img_url) }"
        @mechanize.get(MAIN_URL + img_url).save(img_path)
      end

      @parsed += 1
      @saved.push(hash)
      return 'break' unless @parsed < @goods_qnt
    end

    next_link = subsect_page.at(NEXTPAGE_SEL)
    if next_link
      #puts "Go to page #{ next_link.attributes['href'] }"
      parse_subsect(@mechanize.get(MAIN_URL + '/' + next_link.attributes['href']), sect, subsect)
    end
  end

  def get_row_by_hash(hash)
    return [] unless @saved.index(hash)
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.select{|r| r[5] == hash}[0]
  end

  def stat
    puts "Catalog contains #{ @saved.size } goods."
    return if @saved.size.zero?
    
    # FIX: разобраться с открытием файлов: файл конец файла не совпадает:
    # приходится вручную закрывать файл для записи
    @catalog_file.close
    data = CSV.open(@path, 'r', {:col_sep => @sep}).readlines
    catalog = Hash[data.collect{|r| [r[0], {:qnt => 0}]}]
    data.each do |r|
      catalog[r[0]][r[1]] = [] unless catalog[r[0]][r[1]]
      catalog[r[0]][r[1]].push(r.drop(2))
      catalog[r[0]][:qnt] += 1
    end

    catalog.each do |cat, cat_data|
        puts "#{ cat }: #{ cat_data.delete(:qnt) }"
        cat_data.each do |subcat, subcat_data|
            puts "  #{ subcat }: #{ subcat_data.size }"
        end
    end

    img_list = Dir.glob(@img_dir + '/*.{jpg,jpeg,gif,png}') # с запасом
    return if img_list.count.zero?

    puts "#{ img_list.count } of #{ @saved.size } "\
      "(#{ 100 * img_list.count / @saved.size }%) goods have image."

    img_size_list = img_list.map{|path| File.size(path)}

    img_file_info = Proc.new {|size|
      f_name = File.basename(img_list[img_size_list.index(size)])
      file = {
        :size => size,
        :hash => f_name.split('.')[0],
        :name => f_name,
        :goods => self.get_row_by_hash(f_name.split('.')[0])[2]
      }
    }

    min_f = img_file_info.call(img_size_list.min)
    max_f = img_file_info.call(img_size_list.max)

    average = img_size_list.inject{|sum, el| sum += el}

    to_kb = Proc.new {|size| '%.2fKB.' %(size.to_f/1024)}

    puts "Average: #{ to_kb.call(average.to_f/img_list.count) }"
    puts "Min file #{ min_f[:name] } for #{ min_f[:goods] }: "\
      "#{ to_kb.call(min_f[:size]) }"
    puts "Max file #{ max_f[:name] } for #{ max_f[:goods] }: "\
      "#{ to_kb.call(max_f[:size]) }"
  end
end

cp = PiknikParser.new
cp.stat