class Person < ActiveRecord::Base
  devise :cas_authenticatable, :trackable
  
  has_many :attendances
  has_many :events, :through => :attendances
  
  scope :attending, lambda { |event| joins(:attendances).
    where(["attendances.event_id = ? AND (attendances.deleted_at IS NULL OR attendances.deleted_at > ?)", event.id, Time.now])}

  scope :busy_between, lambda { |start_time, end_time|
    where("people.id IN (#{Attendance.event_between(start_time, end_time).select("attendances.person_id").to_sql})")
  }
  scope :free_between, lambda { |start_time, end_time|
    where("people.id NOT IN (#{Attendance.event_between(start_time, end_time).select("attendances.person_id").to_sql})")
  }
  
  def name
    unless nickname.blank?
      "#{firstname} \"#{nickname}\" #{lastname}"
    else
      "#{firstname} #{lastname}"
    end
  end
  
  def current_age
    age_as_of Date.today
  end
  
  def age_as_of(base = Date.today)
    if not birthdate.nil?
      base.year - birthdate.year - ((base.month * 100 + base.day >= birthdate.month * 100 + birthdate.day) ? 0 : 1)
    end
  end
  
  def merge_person_id!(merge_id)
    count = 0
    
    transaction do
      Attendance.where(:person_id => merge_id).each do |att|
        att.person = self
        att.save(false)
        count += 1
      end
    
      Event.where(:proposer_id => merge_id).each do |event|
        event.proposer = self
        event.save(false)
        count += 1
      end
    end
    
    return count
  end
  
  def attendance_for_event(event)
    event.attendances.select { |att| att.person_id == self.id }.first
  end
  
  def staffer_for_event(event)
    event.staffers.select { |s| s.person.id == self.id }.first
  end
  
  def attending?(event)
    attendance_for_event(event)
  end
  
  def events_cond(events)
    if events.length > 0
      return "AND events.id IN ("+events.collect { |e| e.id }.join(',') + ")"
    else
      return ""
    end
  end

  def busy_at?(time, events=[])
    return Attendance.count(:conditions => ["start <= ? AND end > ? and person_id = ? #{events_cond events}", 
                                            time, time, person.id],
                            :joins => :event) > 0
  end
  
  def busy_between?(start_time, end_time, events=[])
    return (busy_at?(start_time, events) or 
            Attendance.count(:conditions => ["(end > ? AND start <= ?) and person_id = ? #{events_cond events}", 
                                             start_time, end_time, person.id],
                             :joins => :event) > 0)
  end
end