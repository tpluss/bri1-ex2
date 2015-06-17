#coding: utf-8

require 'csv'
require 'digest'
require 'open-uri'
require 'nokogiri'


# Товар
# Описание состоит из:
#   раздел - подраздел - название - адрес карточки - адрес картинки - хэш
# Хэш генерируется в момент создания: SHA-256 из (раздел + подраздел + имя).
class Goods

  attr_reader :cat, :subcat, :name, :href, :img, :hash

  def initialize(*args)
    raise ArgumentError, "Expected args: cat, subcat, name, href, img." unless args.size == 5
    @cat, @subcat, @name, @href, @img = args
    @hash = Digest::SHA256.hexdigest(@cat + @subcat + @name)
  end

  def to_catalog
    [@cat, @subcat, @name, @href, @img, @hash]
  end

  def to_s
    "#{ @cat } > #{ @subcat } > #{ @name }: #{ @href }, #{ @img } (#{ @hash })"
  end
end


# Каталог товаров: бёртка для записи в CSV-файл.
#
# Разделителем CSV-файла является знак \t.
# Формат каталога:
#   Категория | Ссылка на товар | Наименование | Ссылка на картинку | MD5-хэш
#
# Хэш нужен для индикации наличия товара в Каталоге.
class Catalog

  attr_reader :path, :img_dir, :sep, :catalog

  def initialize(path=nil, img_dir=nil, sep=nil)
    @path ||= './catalog.txt'
    @img_dir ||= './img'
    @sep ||= "\t"
    @catalog_file = CSV.open(@path, 'a+', {:col_sep => @sep})

    # Чтобы не дёргать каждый раз файл, создадим массив хэшей, который будет
    # индикатором наличия объекта в каталоге.
    @saved = []

    # Каталог хранится в структуре вида
    # "Колготки, носки" => {
    #   :subcat => {
    #      "/products/tights/socks" => {
    #       :goods => [GoodsItem],
    #       :qnt => autoincrement,
    #     }
    #   },
    #   :qnt => autoincrement
    # }
    @catalog = {}
    @catalog_file.readlines.each do |row|
      # Подсчёт хэша повторяется: добавить проверку источника?
      goods = Goods.new(*row.take(5))
      self.add(goods, save_file=false)
    end

    puts "Catalog stat:"
    self.stat
  end

  def add(goods, save_file=true)
    cat = goods.cat
    subcat = goods.subcat
    hash = goods.hash

    if @saved.index(hash)
      #puts "Already saved: #{ goods.name } (#{ hash })."
      return
    end

    unless @catalog.has_key?(cat)
      @catalog[cat] = {:txt => cat, :subcat => {}, :qnt => 0}
    end

    unless @catalog[cat][:subcat].has_key?(subcat)
      @catalog[cat][:subcat][subcat] = {:goods => [], :qnt => 0} 
    end

    @catalog[cat][:subcat][subcat][:goods].push(goods)

    @catalog[cat][:qnt] += 1
    @catalog[cat][:subcat][subcat][:qnt] += 1

    @saved.push(hash)

    self.to_file(goods) if save_file

    hash
  end

  def to_file(goods)
    @catalog_file << goods.to_catalog
  end
  protected :to_file

  def get_row_by_hash(hash)
    # Поискать метод для перехода к строке - можно будет брать индекс из @saved.
    # Можно перейти на поиск по каталогу
    return unless @saved.index(hash)
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each do |row|
      if row[5] == hash
        return row
      end
    end
  end

  def size
    @saved.size
  end

  def stat
    puts "Catalog contains #{ self.size } goods."

    @catalog.each do |cat_url, cat_data|
      puts "#{ cat_url }: #{ cat_data[:qnt] } pcs."
      cat_data[:subcat].each do |subcat_name, subcat_data|
        puts " -> #{ subcat_name }: #{ subcat_data[:qnt] } pcs.; "\
          "#{ 100 * subcat_data[:qnt]/cat_data[:qnt] }%."
      end
    end

    img_list = Dir.glob(@img_dir + '/*.{jpg,jpeg,gif,png}') # с запасом

    img_qnt = img_list.count
    if img_qnt == 0
      puts "No images saved."
      return
    elsif self.size == 0
      raise RuntimeError, "Remove all files from #{ @img_dir  } before run."
    end

    puts "#{ img_qnt } of #{ self.size } "\
      "(#{ 100 * img_qnt / self.size }%) goods have image."

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

    puts "Average: #{ to_kb.call(average.to_f/img_qnt) }"
    puts "Min file #{ min_f[:name] } for #{ min_f[:goods] }: "\
      "#{ to_kb.call(min_f[:size]) }"
    puts "Max file #{ max_f[:name] } for #{ max_f[:goods] }: "\
      "#{ to_kb.call(max_f[:size]) }"
  end
end


# Парсер каталога: собирает структуру в categories и последовательно обходит её,
# обрабатывая разделы с товарами. Каждый товар отдаётся в Catalog для записи.
class CatalogParser
  def initialize
    @MAIN_URL = 'http://www.piknikvdom.ru'

    @ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '\
      '(KHTML, like Gecko) Chrome/43.0.2357.125 Safari/537.36'
    @goods_qnt = 1000 
    @parsed = 0

    @catalog = Catalog.new

    # "/products/tights" => {
    #   :txt => "Колготки, носки",
    #   :urls => [
    #     {"/products/tights/womens-tights" => "Колготки женские"},
    #     {"/products/tights/socks" => "Носки мужские"}
    #   ]
    # }
    @categories = {}

    begin
      unless Dir.exists?('./img')
        Dir.mkdir('./img')
      end
    rescue Exception => e
      puts "Couldn\'t create image folder. Exit."
      puts e.message
      exit
    end

    self.parse_cat_links

    while @parsed < @goods_qnt
      self.parse_categories

      @catalog.catalog.each do |cat_url, cat_data|
        cat_data[:subcat].each do |subcat_name, subcat_data|
          # У Пикника нет разделов, состоящих лишь из одного подраздела:
          # если у раздела 100% в одном подразделе - добираем записи.
          if subcat_data[:qnt] == cat_data[:qnt]
            puts "There are only one category #{ subcat_name }. Continue."
            @parsed = 0
            break
          end
        end
      end
    end
    @catalog.stat
  end

  # Сбор ссылок по заданному xpath для url
  def get_by_xpath(url, xpath)
    begin
      data = Nokogiri::HTML(open(url, 'User-Agent' => @ua))
      urls = data.xpath(xpath)
    rescue Exception => e
      puts "Couldn\'t connect to #{ url }."
      puts e.message
    end
  end

  def parse_cat_links
    section_xpath = '//div[@class="section"]'
    cat_xpath = './/a[@class="category-image"]'
    goods_xpath = './/p[@class="categories-wrap"]/span/a'

    sections = get_by_xpath(@MAIN_URL + '/products', section_xpath)
    sections.each do |sect|
      cat_a = sect.xpath(cat_xpath).at('a')

      cat_url = cat_a.attributes['href'].value.sub('#list', '')
      @categories[cat_url] = {
        :txt => cat_a.attributes['title'].value, :urls => []
      }

      goods = sect.xpath(goods_xpath)
      goods.each do |_g|
        @categories[cat_url][:urls].push(
          {_g.attributes['href'].value.sub('#list', '') => _g.child.text}
        )
      end
    end
  end

  def parse_categories
    @categories.values.each do |sect|
      sect[:urls].each_with_index do |cat, i|
        # Пока работа при доборе не продолжает с места последнего запуска.
        return if @parsed == @goods_qnt
        continue if sect[:urls][i][cat.keys[0]] == '|'
        parse_category(cat, sect[:txt])
        sect[:urls][i][cat.keys[0]] += '|'
      end
    end
  end

  def parse_category(cat, txt)
    # Наименование товара хранится так же в этом элементе, но нет ссылки на img.
    #goods_link_xpath = '//div[@class="product-card-description"]/a'
    goods_link_xpath = '//a[@class="product-image"]'

    # У них на сайте не работает настройка вывода, но параметр нашёл: count.
    # Можно не делать переходы по страницам - все товары показаны сразу.
    url = @MAIN_URL + cat.keys[0] + '?count=500'
    goods_a = get_by_xpath(url, goods_link_xpath)

    goods_a.each do |goods|
      return if @parsed == @goods_qnt
      parse_goods(txt, cat.values[0], goods)
    end
  end

  def parse_goods(cat, subcat, goods)
    href = goods.attributes['href'].value
    name = goods.at('img').attributes['alt'].value

    # Зато без регэкспов :)
    img_url = goods.attributes['style'].value.sub('background: url(', '')\
      .sub(') no-repeat center center', '').sub('/images/no_photo_2.png', '')

    goods_args = [cat, subcat, name, href, img_url].map{|e| e.gsub('\t', ' ')}
    hash = @catalog.add(Goods.new(*goods_args))
    @parsed +=1 if hash

    if !img_url.empty? and hash
      begin
        img_data = open(URI.encode(@MAIN_URL + img_url)).read
        open("./img/#{ hash }#{ File.extname(img_url) }", 'wb') do |file|
          file << img_data
        end
      rescue Exception => e
        puts "Couldn't save image file for #{ hash }"
        puts e.message
      end
    end
  end
end

cp = CatalogParser.new