#coding: utf-8

require 'csv'
require 'digest'
require 'open-uri'
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
    @saved = @catalog_file.readlines.collect{ |r| r[5] }

    #@goods_qnt = 50
    return    
    @parsed = 0

    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = 'Windows Chrome'
    catalog_page = @mechanize.get(PRODUCTS_URL)
    catalog_page.search(SECTBLOCK_SEL).each do |sect_block|
      sect_title = sect_block.at(SECTLINK_SEL).attributes['title']
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
  end

  def parse_subsect(subsect_page, sect, subsect)
    subsect_page.search(GOODSCARD_SEL).each do |goods_link|
      href = goods_link.attributes['href'].to_s
      name = goods_link.at('img').attributes['alt'].to_s
      # Зато без регэкспов :)
      # FIX: переход в карточку товара с последующим дёрганьем по css-селектору.
      # Товары с no_photo можно пропускать?
      img_url = goods_link.attributes['style'].value.sub('background: url(', '')\
        .sub(') no-repeat center center', '').sub('/images/no_photo_2.png', '')

      hash = Digest::SHA256.hexdigest(sect + subsect + name)
      next if @saved.index(hash)
      @catalog_file << [sect, subsect, name, href, img_url, hash].map{|e| e.gsub('\t', ' ')}
      #puts "    #{ name }"

      # FIX: Кириллица в url => 404.
      if !img_url.empty?
        img_data = open(URI.encode(MAIN_URL + img_url)).read
        open("#{ @img_dir }/#{ hash }#{ File.extname(img_url) }", 'wb') do |file|
          file << img_data
        end
      end

      @parsed +=1
      @saved.push(hash.to_s)
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
    #rows.collect {|r| r if r[5] == hash }.compact[0]
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each do |r|
      return r if r[5] == hash
    end
  end

  def stat
    puts "Catalog contains #{ @saved.size } goods."
    return if @saved.size.zero?
    cur_sect, cur_subsect = nil, nil
    sect_qnt, subsect_qnt = 0, 0
    # Адский обход. Надо предварительно знать количество, а выводить потом.
    # Нужен алгоритм формирования хэша.
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each do |r|
      unless cur_subsect == r[1] #or last line
        puts " Total: #{ subsect_qnt } (#{ '%.2f' %(100.to_f * subsect_qnt/sect_qnt) }%)." unless cur_subsect.nil?
        cur_subsect = r[1]
        puts "  #{ r[1] }"
        subsect_qnt = 0
        unless cur_sect == r[0] #or last line
          puts "Total: #{ sect_qnt }" unless cur_sect.nil?
          cur_sect = r[0]
          puts r[0]
          sect_qnt = 0
        end
      end
      sect_qnt +=1
      subsect_qnt +=1
      puts " -> #{ r[2] }"
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