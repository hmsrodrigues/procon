class Event < ActiveRecord::Base
  has_many :attendances, :order => "created_at", :dependent => :destroy
  has_many :attendee_slots, :foreign_key => "event_id"
  has_many :registration_buckets, :foreign_key => "event_id"
    
  private
  # convenience method for getting the actual people associated with a group
  # of attendances
  #
  # has_many :through won't do it because they're in different databases
  def self.get_people_method(method_name, conditions=nil, with_deleted=false)
    finder_method = with_deleted ? "find_with_deleted" : "find"
    args = ":all"
    if conditions
      args += ", :conditions => #{conditions.to_json}, :select => 'person_id'"
    end
    class_eval <<-ENDMETHOD
      def #{method_name}
        ids = attendances.#{finder_method}(#{args}).map(&:person_id)
        if ids.empty?
          []
        else
          Person.find(:all, :conditions => ["id in (?)", ids])
        end
      end
    ENDMETHOD
  end
  
  public
  
  get_people_method "all_attendees"
  get_people_method "confirmed_attendees", ["is_waitlist = ?", false]
  has_many :confirmed_attendances, :class_name => "Attendance", :order => "created_at", 
    :conditions => ["is_waitlist = ?", false], :dependent => :destroy
  get_people_method "staff", [ "is_staff = ?", true ]
  get_people_method "waitlist_attendees", ["is_waitlist = ?", true]
  has_many :waitlist_attendances, :class_name => "Attendance", :order => "created_at", 
    :conditions => ["is_waitlist = ?", true], :dependent => :destroy
  get_people_method "counted_attendees", ["counts = ?", true]
  has_many :counted_attendances, :class_name => "Attendance", :order => "created_at", 
    :conditions => ["counts = ?", true], :dependent => :destroy
  
  has_many :proposed_events, :foreign_key => "parent_id"
  has_many :event_locations, :dependent => :destroy
  has_many :locations, :through => :event_locations, :dependent => :destroy
  has_many :exclusive_locations, :through => :event_locations, :dependent => :destroy,
    :source => :location, :conditions => ["exclusive = ?", true]
  has_many :shareable_locations, :through => :event_locations, :dependent => :destroy,
    :source => :location, :conditions => ["exclusive = ?", false]

  has_many :staff_positions, :dependent => :destroy, :order => "position"
  get_people_method "general_staff", [ "is_staff = ? and staff_position_id is null", true]

  belongs_to :registration_policy
  has_many :virtual_sites
  belongs_to :proposed_event

  has_many :schedules
  has_and_belongs_to_many :tracks

  has_many :public_info_fields, :dependent => :destroy
  has_many :public_info_values, :through => :public_info_fields, :dependent => :destroy

  acts_as_tree :order => "start"
  named_scope :time_ordered, :order => "#{connection.quote_column_name 'start'}, #{connection.quote_column_name 'end'}"
  named_scope :for_registration, :include => { :attendances => :person, :registration_policy => :rules,
    :attendee_slots => [], :locations => [] }
  named_scope :in_schedule, lambda { |schedule|
        { :joins => :tracks, :conditions => { :tracks => { :id => schedule.track_ids } },
          :group => "events.id", :include => :tracks }
  }
  named_scope :roots, :conditions => { :parent_id => [nil, 0] }

  def set_default_registration_policy
    if registration_policy.nil?
      create_registration_policy
      save
    end

    is_closed = false
    is_exclusive = false
    registration_policy.rules.each do |rule|
      if rule.kind_of? ClosedEventRule
        is_closed = true
      end
      if rule.kind_of? ExclusiveEventRule
        is_exclusive = true
      end
    end
    
    if not is_closed
      ClosedEventRule.create :policy => registration_policy
    end
    
    if not is_exclusive
      ExclusiveEventRule.create :policy => registration_policy
    end
  end
  
  def shortname
    sn = read_attribute(:shortname)
    if not sn.blank?
      return sn
    else
      return fullname
    end
  end
  
  def fullname
    fn = read_attribute(:fullname)
    if fn.blank?
      return "Untitled Event"
    else
      return fn
    end
  end
      
  
  def globally_visible?
    return parent.nil?
  end
  
  def simultaneous_with?(other)
    other.end > self.start && other.start < self.end
  end
  
  def simultaneous_events
    return [] unless self.start and self.end
    
    searchpool = if parent.nil?
      Event.find_all_by_parent_id nil
    else
      parent.children
    end.reject { |e| e == self }.select { |e| e.start && e.end}
    
    searchpool.select { |e| simultaneous_with?(e) }
  end
  
  def shared_locations
    simevents = simultaneous_events
    shareable_locations.select do |loc|
      simevents.collect do |e|
        e.locations.include? loc
      end.include? true
    end
  end
   
  def attendees_visible_to?(person)
    Ability.new(person).can?(:view_attendances, self)
  end
  
  def attendance_errors(attendance, other_atts=nil)
    errs = []
    if !attendance.is_staff? && counts_for_max_attendances? && parent.try(:limits_child_event_attendances?)
      other_att_count = if other_atts
        other_atts.count do |att|
          evt = att.event
          (att.person_id == attendance.person_id && evt.parent_id == parent.id &&
          evt.counts_for_max_attendances? && !att.is_staff && evt.id != id)
        end
      else 
        Attendance.count(:joins => :event, 
        :conditions => [
          "attendances.person_id = ? AND events.parent_id = ? AND events.counts_for_max_attendances = ? AND events.id != ?
           AND (attendances.is_staff = 0 OR attendances.is_staff IS NULL)",
          attendance.person_id, parent.id, true, id])
      end
      max_atts = parent.max_child_event_attendances
      if other_att_count >= max_atts
        errs << "You can only sign up for #{max_atts} #{max_atts == 1 ? 'event' : 'events'} at this time."
      end
    end
    if not registration_policy.nil?
      registration_policy.rules.each do |rule|
        if not rule.attendance_valid?(attendance, other_atts)
          errs << rule.error_message(attendance)
        end
      end
    end
    return errs
  end
  
  def attendance_invalid?(attendance)
    if not attendance.event.registration_policy.nil?
      if not attendance.event.registration_policy.attendance_valid?(attendance)
        return "The event's registration policy does not allow you to sign up."
      end
    end
  end
  
  def attendee_count(gender=nil)
    if gender.nil?
      attendances.select { |att| att.counts }.size
    else
      attendances.select { |att| att.counts and att.gender == gender }.size
    end
  end
  
  def waitlist_count(gender=nil)
    if gender.nil?
      attendances.select { |att| att.is_waitlist }.size
    else
      attendances.select { |att| att.is_waitlist and att.gender == gender }.size
    end
  end
  
  def avg_age
    count = 0
    total = 0
    attendances.find_all_by_counts(true).each do |a|
      age = a.age
      if not age.nil?
        count += 1
        total += age
      end
    end
    return total.to_f / count
  end
  
  def length
    if self.end and self.start
      self.end - self.start
    end
  end
  
  def obtain_registration_policy
    if registration_policy.nil?
      return create_registration_policy
    else
      return registration_policy
    end
  end
  
  def pull_from_children
    children_attendees = children.collect { |c| c.all_attendees }.flatten.uniq
    my_attendees = self.all_attendees
    children_attendees.each do |person|
      if not my_attendees.include? person
        Attendance.create :person => person, :event => self
      end
    end
  end
  
  def registration_open
    not obtain_registration_policy.contains_rule_type? ClosedEventRule
  end

  def registration_open=(reg_open)
    policy = obtain_registration_policy

    if param_to_bool(reg_open)
      policy.each_rule_of_type ClosedEventRule do |rule|
        rule.destroy
      end
    else
      if not policy.contains_rule_type? ClosedEventRule
        ClosedEventRule.create :policy => policy
      end
    end
  end
  
  def non_exclusive
    not obtain_registration_policy.contains_rule_type? ExclusiveEventRule
  end

  def non_exclusive=(non_exc)
    policy = obtain_registration_policy

    if param_to_bool(non_exc)
      policy.each_rule_of_type ExclusiveEventRule do |rule|
        rule.destroy
      end
    else
      if not policy.contains_rule_type? ExclusiveEventRule
        ExclusiveEventRule.create :policy => policy
      end
    end
  end
  
  def age_restricted
    obtain_registration_policy.contains_rule_type? AgeRestrictionRule
  end

  def min_age
    policy = obtain_registration_policy

    if policy.contains_rule_type? AgeRestrictionRule
      return policy.rules.find_all_by_type('AgeRestrictionRule').collect { |r| r.min_age }.max
    else
      return nil
    end
  end

  def min_age=(ma)
    policy = obtain_registration_policy

    if ma.to_i > 0
      if not policy.contains_rule_type? AgeRestrictionRule
        AgeRestrictionRule.create :policy => policy
      end
      policy.reload
      policy.each_rule_of_type AgeRestrictionRule do |rule|
        rule.min_age = ma
        rule.save
      end
    else
      policy.each_rule_of_type AgeRestrictionRule do |rule|
        rule.destroy
      end
    end
  end
        
  def to_xml
    super(:methods => [:min_age, :age_restricted, :registration_open, :non_exclusive])
  end

  def attendees_with_blank_agenda
    child_ids = children.collect { |c| c.id }
    attendance_count = Attendance.count(:group => :person_id, :conditions => { :event_id => child_ids })

    return confirmed_attendees.reject { |p| attendance_count.has_key?(p.id) || attendance_count[p.id] == 0 }
  end
  
  def limits_child_event_attendances?
    max_child_event_attendances.present?
  end

  private
  def param_to_bool(param)
    if param.blank?
      return false
    else
      return param.to_s.downcase == "true"
    end
  end
  
  def gendered?
    false
  end
end
