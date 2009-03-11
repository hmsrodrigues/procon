class Schedule < ActiveRecord::Base
  has_many :tracks, :order => :position
  belongs_to :event
  has_many :schedule_blocks, :order => :start
  
  def events
    events = []
    event_tracks = {}
    tracks.each do |track|
      track.events.each do |event|
        if not events.include? event
          events.push event
        end
      end
    end
    return events.sort {|a,b| a.start == b.start ? a.end <=> b.end : a.start <=> b.start }
  end

  def all_events_registration_open=(status)
    events.each do |event|
      event.registration_open = status
      event.save
    end
  end
  
  def obtain_blocks
    # heuristically split events into logical "blocks" of time
    current_block = []
    blocked_events = schedule_blocks.collect { |b| b.events }.flatten
    non_blocked_events = events.select { |e| not blocked_events.include?(e) }

    high_water_mark = nil
    non_blocked_events.each do |event|
      if high_water_mark.nil?
        high_water_mark = event.end
      end
      
      if high_water_mark < (event.start - 3.hours)
        if current_block.size > 0
          block = self.schedule_blocks.create :events => current_block
          current_block = []
        end
      end
      
      current_block.push(event)
      
      if high_water_mark < event.end
        high_water_mark = event.end
      end
    end
    if current_block.size > 0
      block = self.schedule_blocks.create :events => current_block
    end
    
    return self.schedule_blocks
  end
end
