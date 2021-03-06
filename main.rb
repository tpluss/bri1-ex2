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
  GOODSIMG_SEL = 'div.prettyphoto'

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

    @goods_qnt = 1000
    @parsed = 0

    self.parse
    self.stat
  end

  def parse
    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = 'Windows Chrome'

    img_saver = Mechanize.new # Отдельный инстанс нужен: segafult в nokogiri.so

    catalog_page = @mechanize.get(PRODUCTS_URL)
    catalog_page.search(SECTBLOCK_SEL).each do |sect_block|
      sect_title = sect_block.at(SECTLINK_SEL).attributes['title'].to_s
      puts "Works on #{ sect_title }"

      sect_block.search(SUBSECT_SEL).each do |subsect_url|
        subsect_title = subsect_url.text
        puts "  Parse #{ subsect_title }"

        subsect_goods = self.get_subsect_goods(subsect_url.attributes['href'])
        subsect_goods.each do |goods|
          return if @parsed == @goods_qnt

          href = goods.attributes['href'].to_s
          name = goods.at('img').attributes['alt'].to_s
          hash = Digest::SHA256.hexdigest(sect_title + subsect_title + name)
          next if @saved.index(hash)         

          unless goods.attributes['style'].to_s.index('no_photo')
            goods_card = img_saver.get(MAIN_URL + goods.attributes['href'])
            img_url = goods_card.at(GOODSIMG_SEL).attributes['href'].to_s
            img_path = "#{ @img_dir }/#{ hash }#{ File.extname(img_url) }"
            img_saver.get(MAIN_URL + img_url).save(img_path)
          end

          @catalog_file << [sect_title, subsect_title, name, href, img_url, hash]
          puts "    #{ name }"

          @parsed += 1
          @saved.push(hash)
        end
      end
    end
  end

  # Собирает все ссылки на товары по категории
  # ??? Такой подход не очень нравится, так как придётся обойти все страницы
  # раздела, а потом считать хэш: товары в каталоге могут дублироваться.
  def get_subsect_goods(subsect_href)
    subsect_page = @mechanize.get(subsect_href)
    res = subsect_page.search(GOODSCARD_SEL)

    next_link = subsect_page.at(NEXTPAGE_SEL)
    if next_link
      href = next_link.attributes['href']
      #puts "  Next page #{ MAIN_URL + href }"
      res += self.get_subsect_goods(MAIN_URL + href)
    end

    res
  end

  def get_row_by_hash(hash)
    return [] unless @saved.index(hash)
    @catalog_file.pos = 0
    @catalog_file.readlines.select{|r| r[5] == hash}[0]
  end

  def stat
    puts "Catalog contains #{ @saved.size } goods."
    return if @saved.size.zero?

    # Буфер к этому моменту не всегда записан в файл: пишем вручную
    @catalog_file.flush
    # Смещаем каретку на начало, чтобы не открывать заново
    @catalog_file.pos = 0

    data = @catalog_file.readlines
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
    return if img_list.empty?

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

    if catalog.values.size == 1 && catalog.values[0].values.size == 1
      puts "All goods from one subcategory. Restart!"
      @parsed = 0
      self.parse
    end
  end
end

cp = PiknikParser.new