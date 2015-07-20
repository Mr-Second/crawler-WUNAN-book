require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'
require 'isbn'

require 'thread'
require 'thwait'

class WunanBookCrawler
  include CrawlerRocks::DSL

  ATTR_HASH = {
    "作者" => :author,
    "出版社" => :publisher,
    "出版日" => :date,
    "定價" => :price,
  }

  def initialize
    @index_url = "http://www.wunanbooks.com.tw"
  end

  def books
    @books = {}
    @threads = []
    visit @index_url

    # @doc.css('a').map{|a| a[:href] }.delete(nil).delete("").map{|href| URI.join(@index_url, href).to_s }
    # http://www.wunanbooks.com.tw/BookCip.aspx?ID=19&Cat_id=21030&Cat=Cip2&tree=2
    # http://www.wunanbooks.com.tw/BookCip.aspx?Cat_id=110&Cat=Cip1
    # http://www.wunanbooks.com.tw/publisher.aspx?uid=0178

    # 用主題分類爬吧
    category_urls = Hash[ @doc.css('a')\
      .select{|d| d[:href].match(/BookCip.aspx\?Cat_id/) }
      .map{|a| [a.text, URI.join(@index_url, a[:href]).to_s ] }
    ]
    # category_urls.keys[1..1].each do |category|
    category_urls.keys.each do |category|
      category_url = category_urls[category]
      print "start category: #{category}"

      r = RestClient.get category_url
      doc = Nokogiri::HTML(r)

      @cookies = r.cookies

      page_num = doc.css('a').select{|a| a[:href] && a[:href].match(/javascript:__doPostBack/)}.map{|a| a[:href].match(/(?<=javascript:__doPostBack\(\'ctl00\$ContentPlaceHolder1\$pager\',\')\d+/).to_s.to_i}.max

      parse_book_list(doc)

      (2..page_num).each do |i|
        sleep(1) until (
          @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
          @threads.count < (ENV['MAX_THREADS'] || 10)
        )
        @threads << Thread.new do
          view_state = Hash[ doc.css('#aspnetForm input[type="hidden"]').map{|input| [ input[:name], input[:value] ]} ]

          r = RestClient.post(category_url, view_state.merge({
            "__EVENTTARGET" => 'ctl00$ContentPlaceHolder1$pager',
            "__EVENTARGUMENT" => i
          }), cookies: @cookies)

          doc = Nokogiri::HTML(r)

          parse_book_list(doc)

          print "|"
        end
      end if page_num && page_num > 1
    end
    ThreadsWait.all_waits(*@threads)

    @books.values
  end

  def parse_book_list doc
    doc.xpath('//table[@width="265"]/tr').each do |tr|

      url = URI.join(@index_url, tr.xpath('td[1]/table/tr/td/a/@href').to_s).to_s
      external_image_url = URI.join(@index_url, tr.xpath('td[1]/table/tr/td/a/img/@src').to_s).to_s

      isbn = url.match(/(?<=product\/).+/).to_s

      begin
        isbn = isbn_to_13(isbn)
      rescue Exception => e
      end

      data_rows = tr.xpath('td[2]/table/tr')
      name = data_rows[0].text

      @books[isbn] = {
        name: name,
        isbn: isbn,
        external_image_url: external_image_url,
        url: url
      }

      data_rows[1..-1].map{|r| r.text.strip}.each {|attr_data|
        key = attr_data.rpartition('：')[0]
        @books[isbn][ATTR_HASH[key]] = attr_data.rpartition('：')[-1] if ATTR_HASH[key]
      }

      @books[isbn][:price] = @books[isbn][:price].gsub(/[^\d]/, '').to_i
    end

  end

  def isbn_to_13 isbn
    case isbn.length
    when 13
      return ISBN.thirteen isbn
    when 10
      return ISBN.thirteen isbn
    when 12
      return "#{isbn}#{isbn_checksum(isbn)}"
    when 9
      return ISBN.thirteen("#{isbn}#{isbn_checksum(isbn)}")
    end
  end

  def isbn_checksum(isbn)
    isbn.gsub!(/[^(\d|X)]/, '')
    c = 0
    if isbn.length <= 10
      10.downto(2) {|i| c += isbn[10-i].to_i * i}
      c %= 11
      c = 11 - c
      c ='X' if c == 10
      return c
    elsif isbn.length <= 13
      (1..11).step(2) {|i| c += isbn[i].to_i}
      c *= 3
      (0..11).step(2) {|i| c += isbn[i].to_i}
      c = (220-c) % 10
      return c
    end
  end
end

cc = WunanBookCrawler.new
File.write('wunan_books.json', JSON.pretty_generate(cc.books))
