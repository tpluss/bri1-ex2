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
    raise Argument error unless args.size == 5
    @cat, @subcat, @name, @href, @img = args
    @hash = Digest::SHA256.hexdigest(@cat + @subcat + @name)
  end

  def to_catalog
    # santitize - подстраховка на случай табуляции в данных с сайта.
    [@cat, @subcat, @href, @name, @img, @hash].map{|e| e.gsub('\t', ' ')}
  end
end


#TODO
# П. 1 задания
# Придмать нормальная имена переменным: bc, h1
# get_links переименовать (в get_xpath?)

# Каталог товаров: бёртка для записи в CSV-файл.
#
# Разделителем CSV-файла является знак \t.
# Формат каталога:
#   Категория | Ссылка на товар | Наименование | Ссылка на картинку | MD5-хэш
#
# Хэш нужен для индикации наличия товара в Каталоге.
class Catalog

  attr_acessor :path, :img_dir, :sep

  def initialize(path, img_dir, sep)
    @path |= './catalog.txt'
    @img_dir |= './img'
    @sep |= "\t"
    @instance = CSV.open(@path, 'a+', {:col_sep => @sep})

    # Чтобы не дёргать каждый раз файл, создадим массив хэшей, который будет
    # индикатором наличия объекта в каталоге.
    @saved = []
    @instance.readlines.each do |l|
      @saved.push(l[5])
    end

    #self.stat
  end

  def write(goods)
    raise ArgumentError unless goods.is_a? Goods
    if !@saved.index(goods.hash)
      @instance << goods.to_catalog
      goods.hash
    else
      puts "#{ goods.name } (#{ goods.hash }) already saved."
    end
  end

  def size
    @saved.size
  end

  def get_by_hash(hash)
    # Поискать метод для перехода к строке - можно будет брать индекс из @saved.
    return unless @saved.index(hash)
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each do |line|
      if line[5] == hash
        return line
      end
    end
  end

  def get_by_group(group)
    res = []
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each do |line|
      if line[0] == group
        res.append(line)
      end
    end

    res
  end

  def stat
    puts "Catalog contains #{ self.size } goods."

    puts "1."
    cat_stat = {}
    CSV.open(@path, 'r', {:col_sep => @sep}).readlines.each {|line|
      cat_stat[line[0]] = 0 unless cat_stat.has_key?(line[0])
      cat_stat[line[0]] += 1
    }

    #1) По группам верхнего уровня, показать суммарное количество товаров в группе
    # (если вся 1000 товаров находится в одной группе, загрузить больше товаров)
    # и процент товаров от общего числа в данной группе

    img_list = Dir.glob(@img_dir + '/*.{jpg,jpeg,gif,png}') # с запасом

    img_qnt = img_list.count
    puts "2. #{ img_qnt } of #{ self.size } "\
      "(#{ 100 * img_qnt / self.size }%) goods have image."

    img_size_list = img_list.map{|path| File.size(path)}

    # Структура для быстрого доступа к более востребованной информации о файле.
    img_file_info = Proc.new {|size|
      file = {
        :size => size,
        :hash => img_list[img_size_list.index(size)],
        :basename => File.basename(img_list[img_size_list.index(size)]).split('.')[0],
       }
    }

    min_f = img_file_info.call(img_size_list.min)
    m_file = img_file_info.call(img_size_list.max)
    # Проверки на nil нет - картинка должна быть учтена в каталоге.
    # В теории и это можно в Proc спрятать, но не усложняю.
    min_f[:good] = self.get_by_hash(min_f[:basename])[2]
    m_file[:good] = self.get_by_hash(m_file[:basename])[2]

    average = img_size_list.inject{|sum, el| sum += el}

    to_kb = Proc.new {|size| "#{ '%.2f' %(size.to_f/1024) }KB."}

    puts "Average: #{ to_kb.call(average.to_f/img_qnt) }"
    puts "Min file #{ min_f[:hash] } for #{ min_f[:good] }: "\
      "#{ to_kb.call(min_f[:size]) }"
    puts "Max file #{ m_file[:hash] } for #{ m_file[:good] }: "\
      "#{ to_kb.call(m_file[:size]) }"
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
      puts e.backtrace.inspect
      exit
    end

    self.parse_main # Сбор ссылок на категории
    self.parse_categories # Обход категорий
  end

  # Сбор ссылок по заданному xpath для url
  def get_links(url, xpath)
    begin
      data = Nokogiri::HTML(open(url, 'User-Agent' => @ua))
      urls = data.xpath(xpath)
    rescue Exception => e
      puts "Couldn\'t connect to #{ url }."
      puts e.message
      puts e.backtrace.inspect
    end
  end

  def parse_main
    section_xpath = '//div[@class="section"]'
    h1_xpath = './/a[@class="category-image"]'
    goods_xpath = './/p[@class="categories-wrap"]/span/a'

    sections = get_links(@MAIN_URL + '/products', section_xpath)
    sections.each do |sect|
      h1_a = sect.xpath(h1_xpath).at('a')

      cat_url = h1_a.attributes['href'].value.sub('#list', '')
      @categories[cat_url] = {
        :txt => h1_a.attributes['title'].value, :urls => []
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
      sect[:urls].each do |cat|
        parse_category(cat, sect[:txt])
      end
    end
  end

  def parse_category(cat, txt)
    # Наименование товара хранится так же в этом элементе, но нет ссылки на img.
    #goods_link_xpath = '//div[@class="product-card-description"]/a'
    goods_link_xpath = '//a[@class="product-image"]'

    # У них на сайте не работает настройка вывода, но параметр нашёл: count.
    # Можно не делать переходы по страницам - все товары показаны сразу.
    goods_a = get_links(@MAIN_URL + cat.keys[0] + '/?count=2', goods_link_xpath)

    goods_a.each do |goods|
      parse_goods([txt, cat.values[0]], goods)
    end
  end

  def parse_goods(bc, goods)
    href = goods.attributes['href'].value
    name = goods.at('img').attributes['alt'].value

    # Зато без регэкспов :)
    img_url = goods.attributes['style'].value.sub('background: url(', '')\
      .sub(') no-repeat center center', '').sub('/images/no_photo_2.png', '')

    goods = Goods.new(bc[0], bc[1], href, name, img_url)
    hash = @catalog.write(goods)

    # TODO: Не понимает русские символы
    if !img_url.empty? and hash
      begin
        open("./img/#{ hash }.#{ File.extname(img_url) }", 'wb') do |file|
          file << open(@MAIN_URL + img_url).read
        end
      rescue Exception => e
        puts "Couldn't save image file for #{ hash }"
        puts e.message
        puts e.backtrace.inspect
      end
    end
  end
end

cp = CatalogParser.new