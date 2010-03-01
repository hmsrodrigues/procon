class ProposedEventsController < ApplicationController
  before_filter :check_edit_permissions, :except => [:index, :new, :create]
  require_login

  def proposal_admin?
    logged_in? && logged_in_person.procon_profile.has_edit_permissions?(@context)
  end
  helper_method :proposal_admin?

  # GET /proposed_events
  # GET /proposed_events.xml
  def index
    if proposal_admin?
      @proposed_events = ProposedEvent.all
    else
      @proposed_events = @context.children.all(
        :conditions => ["type = 'ProposedEvent' and proposer_id = ?", logged_in_person.id])
    end

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @proposed_events }
    end
  end

  # GET /proposed_events/1
  # GET /proposed_events/1.xml
  def show
    @proposed_event = ProposedEvent.find(params[:id])

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @proposed_event }
    end
  end

  # GET /proposed_events/new
  # GET /proposed_events/new.xml
  def new
    @event = ProposedEvent.new
    if @context
      @event.parent = @context
    end
    calculate_edit_vars
  end

  # GET /proposed_events/1/edit
  def edit
    @event = ProposedEvent.find(params[:id])
    calculate_edit_vars
  end

  # POST /proposed_events
  # POST /proposed_events.xml
  def create
    @event = ProposedEvent.new(params[:event])
    if @context
      @event.parent = @context
    end
    @event.proposer ||= logged_in_person

    if @event.save
      unless @event.staff.include?(@event.proposer)
        a = Attendance.new :person => @event.proposer, :event => @event, :is_staff => true, :counts => false
        if not a.save
          flash[:error_messages].push("Could not add the event proposer as a staff member: #{a.errors.full_messages.join(", ")}")
          return render :action => "new"
        end
      end
      
      redirect_to @event
    else
      render :action => "new"
    end
  end

  # PUT /proposed_events/1
  # PUT /proposed_events/1.xml
  def update
    @proposed_event = ProposedEvent.find(params[:id])

    respond_to do |format|
      if @proposed_event.update_attributes(params[:event])
        flash[:notice] = 'ProposedEvent was successfully updated.'
        format.html { redirect_to(@proposed_event) }
        format.xml  { head :ok }
      else
        format.html { render :action => "edit" }
        format.xml  { render :xml => @proposed_event.errors, :status => :unprocessable_entity }
      end
    end
  end

  def accept
    @proposed_event = ProposedEvent.find(params[:id])

    if @proposed_event.proposed_capacity_limits.blank?
      @event = Event.new
    else
      @event = LimitedCapacityEvent.new
    end

    @event.parent = @context

    %w{fullname shortname blurb description min_age non_exclusive}.each do |attr|
      @event.send("#{attr}=", @proposed_event.send(attr))
    end

    calculate_edit_vars
  end

  private

  def calculate_edit_vars
    @limited_capacity = @event.kind_of? LimitedCapacityEvent
    @limits = {}
    %w(male female neutral).each do |gender|
      @limits[gender] = {}
      slot = nil
      if @limited_capacity
        slot = @event.attendee_slots.find_by_gender(gender)
      end
      %w(min preferred max).each do |threshold|
        if slot.nil?
          limit = 0
        else
          limit = slot.send(threshold)
        end
        @limits[gender][threshold] = limit
      end
    end

    @registration_open = @event.registration_open
    @non_exclusive = @event.non_exclusive
    @age_restricted = @event.age_restricted
    @min_age = @event.min_age
  end
  
  def check_edit_permissions
    if params[:id]
      @proposed_event = ProposedEvent.find(params[:id])

      if @proposed_event && @proposed_event.proposer == logged_in_person
        return
      end
    end

    unless proposal_admin?
      flash[:error_messages] = ["You aren't a proposal administrator for #{@context.fullname}."]
      redirect_to event_url(@context)
    end
  end
end