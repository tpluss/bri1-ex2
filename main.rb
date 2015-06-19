#coding: utf-8

require 'csv'
require 'digest'
require 'open-uri'
require 'mechanize'

# Парсер каталога: собирает структуру в categories и последовательно обходит её,
# обрабатывая разделы с товарами. Каждый товар отдаётся в Catalog для записи.
# Каталог товаров: обёртка для записи в CSV-файл.
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

  CSV_SEP = "\t"
  CAT_PATH = './catalog.txt'
  IMG_PATH  = './img'

  def initialize(path=nil, sep=nil, img_dir=nil)
    @path ||= CAT_PATH
    @sep ||= CSV_SEP

    @img_dir ||= IMG_PATH
    unless Dir.exists?(@img_dir)
      Dir.mkdir(@img_dir)
    end

    @catalog_file = CSV.open(@path, 'a+', {:col_sep => @sep})

    # Чтобы не дёргать каждый раз файл, создадим массив хэшей, который будет
    # индикатором наличия объекта в каталоге.
    @saved = @catalog_file.readlines.collect{ |r| r[5] }

    @goods_qnt = 10 
    @parsed = 0

    @mechanize = Mechanize.new
    @mechanize.user_agent_alias = 'Windows Chrome'
    catalog_page = @mechanize.get(PRODUCTS_URL)
    catalog_page.search(SECTBLOCK_SEL).each do |sect_block|
      sect_title = sect_block.at(SECTLINK_SEL).attributes['title'].to_s
      puts "Works on #{ sect_title }"

      sect_block.search(SUBSECT_SEL).each do |subsect_url|
        puts "  Parse #{ subsect_url.text }"
        status = self.parse_subsect(@mechanize.get(subsect_url.attributes['href']), sect_title, subsect_url.text)
        return if status == 'break'
      end
    end
  end

  def parse_subsect(subsect_page, sect, subsect)
    subsect_page.search('a.product-image').each do |goods_link|
      href = goods_link.attributes['href'].to_s
      name = goods_link.at('img').attributes['alt'].to_s
       # Зато без регэкспов :)
      img_url = goods_link.attributes['style'].value.sub('background: url(', '')\
        .sub(') no-repeat center center', '').sub('/images/no_photo_2.png', '')

      hash = Digest::SHA256.hexdigest(sect + subsect + name)
      next if @saved.index(hash)
      @catalog_file << [sect, subsect, name, href, img_url, hash].map{|e| e.gsub('\t', ' ')}
      puts "    #{ name }"

      # FIX: Кириллица в url => 404.
      if !img_url.empty?
        img_data = open(URI.encode(MAIN_URL + img_url)).read
        open("#{ @img_dir }/#{ hash }#{ File.extname(img_url) }", 'wb') do |file|
          file << img_data
        end
      end

      @parsed +=1
      return 'break' unless @parsed < @goods_qnt
    end

    if subsect_page.at('a.pager-next')
      puts "Go to page #{ subsect_page.at('a.pager-next').attributes['href'] }"
      parse_subsect(@mechanize.get(subsect_page.at('a.pager-next').attributes['href']), sect, subsect)
    end
  end

  def get_row_by_hash(hash)
    return unless @saved.index(hash)
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.select {|r| r[5] == hash}
  end

  def stat
    puts "Catalog contains #{ @saved.size } goods."

    # @catalog.each do |cat_url, cat_data|
      # puts "#{ cat_url }: #{ cat_data[:qnt] } pcs."
      # cat_data[:subcat].each do |subcat_name, subcat_data|
        # puts " -> #{ subcat_name }: #{ subcat_data[:qnt] } pcs.; "\
          # "#{ '%.2f' %(100.to_f * subcat_data[:qnt]/cat_data[:qnt]) }%."
      # end
    # end

    img_list = Dir.glob(@img_dir + '/*.{jpg,jpeg,gif,png}') # с запасом
    return if img_list.count == 0

    puts "#{ img_list.count } of #{ @saved.size } "\
      "(#{ 100 * img_list.count / @saved.size }%) goods have image."

    img_size_list = img_list.map{|path| File.size(path)}

    # Структура для быстрого доступа к более востребованной информации о файле.
    img_file_info = Proc.new {|size|
      f_name = File.basename(img_list[img_size_list.index(size)])
      file = {
        :size => size,
        :hash => f_name.split('.')[0],
        :name => f_name
       }
    }

    min_f = img_file_info.call(img_size_list.min)
    max_f = img_file_info.call(img_size_list.max)
    # Проверки на nil нет - картинка должна быть учтена в каталоге.
    # В теории и это можно в Proc спрятать, но не усложняю.
    min_f[:goods] = self.get_row_by_hash(min_f[:hash])[2]
    max_f[:goods] = self.get_row_by_hash(max_f[:hash])[2]

    average = img_size_list.inject{|sum, el| sum += el}

    to_kb = Proc.new {|size| "#{ '%.2f' %(size.to_f/1024) }KB."}

    puts "Average: #{ to_kb.call(average.to_f/img_list.count) }"
    puts "Min file #{ min_f[:name] } for #{ min_f[:goods] }: "\
      "#{ to_kb.call(min_f[:size]) }"
    puts "Max file #{ max_f[:name] } for #{ max_f[:goods] }: "\
      "#{ to_kb.call(max_f[:size]) }"
  end
end

cp = PiknikParser.new