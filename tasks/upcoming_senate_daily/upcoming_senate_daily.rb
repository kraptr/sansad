require 'feedzirra'
require 'nokogiri'

class UpcomingSenateDaily
  
  def self.run(options = {})
    count = 0
    bill_count = 0
    
    url = "https://democrats.senate.gov/floor/daily-summary/feed/"
    
    rss = nil
    begin
      # rss = Feedzirra::Feed.fetch_and_parse url
      rss = Feedzirra::Feed.parse open("rss.xml").read
    rescue ex
      Report.warning self, "Network error on fetching Senate Daily Summary feed, can't go on.", :url => url
      return
    end
    
    # accumulate upcoming bills 
    upcoming_bills = {}
    
    rss.entries.each do |entry|
      doc = Nokogiri::HTML entry.content
      root = doc.at "/html/body/ul"
      
      legislative_date = Time.parse entry.title
      legislative_day = legislative_date.strftime "%Y-%m-%d"
      session = Utils.session_for_year legislative_date.year
      
      # don't care unless it's today or in the future
      next if legislative_date.midnight < 2.days.ago.midnight # Time.now.midnight
      
      upcoming_bills[legislative_day] = {}
      text_pieces = []
      day_bill_ids = []
      
      root.xpath("li").each_with_index do |item, i|
        
        text = item.text
            
        # figure out the text item, including any following sub-items
        if item.next_element and item.next_element.name == "ul"
          text << "\n"
          item.next_element.xpath("li").each do |subitem|
            text << "\n* #{subitem.text}"
          end
        end
        
        text_pieces << text
        
        bill_ids = bill_ids_for text, session
        day_bill_ids += bill_ids
        
        bill_ids.each do |bill_id|
          if upcoming_bills[legislative_day][bill_id]
            upcoming_bills[legislative_day][bill_id][:context] << text
          else
            upcoming_bills[legislative_day][bill_id] = {
              :session => session,
              :upcoming_type => "bill",
              :chamber => "house",
              :context => [text],
              :bill_id => bill_id,
              :legislative_day => legislative_day,
              :source_type => "senate_daily",
              :source_url => entry.url,
              :bill => Utils.bill_for(bill_id)
            }
          end
        end
      end
      
      schedule = Upcoming.find_or_initialize_by(
        :source_type => "senate_daily",
        :upcoming_type => "schedule",
        :legislative_day => legislative_day
      )
      
      schedule.attributes = {
        :chamber => "house",
        :session => session,
        :legislative_day => legislative_day,
        :bill_ids => day_bill_ids.uniq,
        :items => text_pieces,
        :original => entry.content.strip,
        :source_url => entry.url
      }
      
      schedule.save!
      
      puts "[#{legislative_day}][senate_daily][schedule] Created/updated schedule" if config[:debug]
      count += 1
      
    end
    
    Report.success self, "Created or updated #{count} schedules"
    
    # create any accumulated upcoming bills
    upcoming_bills.each do |legislative_day, bills|
      # clear out the previous items for that legislative day
      Upcoming.where(
        :upcoming_type => "bill",
        :source_type => "senate_daily",
        :legislative_day => legislative_day
      ).delete_all
      
      puts "[#{legislative_day}][senate_daily][bill] Cleared upcoming bills" if config[:debug]
      
      bills.each do |bill_id, bill|
        Upcoming.create! bill
        bill_count += 1
      end
      
    end
    
    Report.success self, "Created or updated #{bill_count} upcoming bills"
  end
  
  def self.bill_ids_for(text, session)
    matches = text.scan(/((S\.|H\.)(\s?J\.|\s?R\.|\s?Con\.| ?)(\s?Res\.?)*\s?\d+)/i).map {|r| r.first}.uniq.compact
    matches = matches.map {|code| bill_code_to_id code, session}
    matches.uniq
  end
    
  def self.bill_code_to_id(code, session)
    "#{code.gsub(/con/i, "c").tr(" ", "").tr('.', '').downcase}-#{session}"
  end
  
end