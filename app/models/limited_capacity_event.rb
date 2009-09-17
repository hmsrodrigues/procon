class LimitedCapacityEvent < Event
  alias_method :attendance_invalid_without_limit_checks?, :attendance_invalid?
  def attendance_invalid?(attendance)
    if err = attendance_invalid_without_limit_checks?(attendance)
      return err
    end
    
    return attendance_over_limit?(attendance)
  end

  def attendance_invalid_if_new?(attendance)
    if err = attendance_invalid_without_limit_checks?(attendance)
      return err
    end
    
    return attendance_over_limit_if_new?(attendance)
  end
  
  def attendance_errors(attendance)
    errs = super(attendance)
    
    overlimit = attendance_over_limit?(attendance)
    if overlimit
      errs << overlimit
    end
    
    return errs
  end
  
  def attendance_over_limit?(attendance)
    if not attendance.counts or attendances.include? attendance
      # don't invalidate attendances that are already signed up
      return false
    else
      # this attendance is new to this event
      return attendance_over_limit_if_new?(attendance)
    end
  end

  def attendance_over_limit_if_new?(attendance)
    attendee_slots.each do |slot|
      if slot.gender.nil? or slot.gender == 'neutral' or slot.gender == attendance.gender
        if not slot.full?
          return false
        end
      end
    end
    return "That event has reached its capacity."
  end

  def gender_slot(gender)
    if @gender_slots.nil?
      @gender_slots = {}
      attendee_slots.each do |slot|
        @gender_slots[slot.gender] = slot
      end
    end
    @gender_slots[gender]
  end
  
  def slot_count(gender, threshold)
    if gender.nil?
      total = 0
      attendee_slots.each do |slot|
        total += slot.send(threshold)
      end
      return total
    else
      slot = gender_slot(gender)
      if slot.nil?
        return 0
      else
        return slot.send(threshold)
      end
    end
  end
  
  %w(min max preferred).each do |threshold|
    self.class_eval <<-ENDCODE
      def #{threshold}_count(gender=nil)
        return slot_count(gender, '#{threshold}')
      end
    ENDCODE
  end
  
  def capacity_limit(threshold, opts={})
    slot_count(opts[:gender], threshold)
  end
  
  def open_slots(gender=nil)
    if gender == 'neutral'
      gendered_slot_count = {}
      neutral_slot_count = 0
      attendee_slots.each do |slot|
        if slot.gender and slot.gender != 'neutral'
          gendered_slot_count[slot.gender] ||= 0
          gendered_slot_count[slot.gender] += slot.max
        else
          neutral_slot_count += slot.max
        end
      end
      total = neutral_slot_count
      spillover = {}
      gendered_slot_count.each_pair do |gender, count|
        spillover = attendee_count(gender) - count
        if spillover < 0
          spillover = 0
        end
        total -= spillover
      end
    else
      total = max_count(gender) - attendee_count(gender)
    end
    
    if total < 0
      return 0
    else
      return total
    end
  end
  
  def gendered?
    attendee_slots.any? {|s| s.gender and s.gender != 'neutral' and s.min > 0 }
  end
  
  def full?
    attendee_slots.each do |slot| 
      if not slot.full?
        return false
      end
    end
    return true
  end
  
  def full_for_gender?(gender)
    open_count = open_slots(gender)
    if gender and gender != "neutral"
      open_count += open_slots("neutral")
    end
    return open_count <= 0
  end
  
  def at_min?
    attendee_slots.each do |slot| 
      unless slot.at_min? or slot.gender.nil? or slot.gender == "neutral"
        return false
      end
    end
    return attendee_count >= min_count
  end
  
  def at_preferred?
    attendee_slots.each do |slot| 
      unless slot.at_preferred? or slot.gender.nil? or slot.gender == "neutral"
        return false
      end
    end
    return attendee_count >= preferred_count
  end
  
  def waitlist_number(person)
    wa = attendances.select {|att| att.person == person and att.is_waitlist }
    if wa.size > 0
      return waitlist_attendances.index(wa[0]) + 1
    else
      return nil
    end
  end
  
  def pull_from_waitlist
    while not full? and waitlist_attendances.count > 0
      successful = false
      waitlist_attendances.each do |wa|
        wa.is_waitlist = false
        wa.counts = true
        # treat this as if if was a new signup for validation purposes
        unless attendance_invalid_if_new?(wa)
          wa.save(false)
          successful = true
          break
        end
      end
      if not successful
        break
      end
    end
    self.reload
  end
end
