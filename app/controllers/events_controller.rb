# frozen_string_literal: true

require "humanize"

# controller for Events

# rubocop:disable Metrics/ClassLength
class EventsController < ApplicationController
  before_action :authenticate_user!
  before_action :find_unit, only: %i[index create new edit edit_rsvps bulk_publish]
  before_action :find_event, except: %i[index create new bulk_publish]
  around_action :set_time_zone

  def index
    @events = UnitEventQuery.new(@current_member).execute
    @event_drafts = @events.select { |e| e.draft? }
    @presenter = EventPresenter.new
    @current_family = @current_member.family
    @current_year = @current_month = nil
    page_title @unit.name, t('events.index.title')
    respond_to do |format|
      format.html
      format.pdf do
        render_calendar
      end
    end
  end

  def render_calendar
    render(
      locals: { events_by_month: calendar_events },
      pdf: "#{@unit.name} Event Calendar",
      layout: "pdf",
      encoding: "utf8",
      orientation: "landscape",
      header: { html: { template: "events/partials/index/calendar_header", locals: { events_by_month: calendar_events } } },
      footer: { html: { template: "events/partials/index/calendar_footer", locals: { events_by_month: calendar_events } } },
      margin: { top: 20, bottom: 20 }
    )
  end

  def calendar_events
    events = @unit.events.includes(:event_category).published
    events = events.reject { |e| e.category.name == "Troop Meeting" } # TODO: not hard-wire this
    events.group_by { |e| [e.starts_at.year, e.starts_at.month] }
  end

  def show
    authorize @event

    @event_view = EventView.new(@event)
    @can_edit = policy(@event).edit?
    @can_organize = policy(@event).organize?
    @current_family = @current_member.family
    page_title @event.unit.name, @event.title
  end

  def new
    build_prototype_event
    @event_view = EventView.new(@event)
    ap @event_view
    @presenter = EventPresenter.new(event: @event, current_user: current_user)
  end

  def create
    authorize :event, :create?

    @event_view = EventView.new(@unit.events.new)
    @event_view.assign_attributes(event_params)
    return unless @event_view.save!

    flash[:notice] = t('helpers.label.event.create_confirmation', event_name: @event_view.title)
    redirect_to [@unit, @event]
  end

  def edit
    authorize @event
    @event_view = EventView.new(@event)
  end

  def update
    authorize @event

    @event_view = EventView.new(@event)
    @event_view.assign_attributes(event_params)
    return unless @event_view.save!

    # render turbo_stream: turbo_stream.replace(@event, partial: 'events/event', locals: { event: @event })

    flash[:notice] = t("events.update_confirmation", title: @event.title)
    redirect_to [@unit, @event]
  end

  def organize
    authorize @event
    @page_title = [@event.title, "Organize"]
    @non_respondents = @event.unit.members.status_active + @event.rsvps.collect(&:member)
    @non_invitees = @event.unit.members.status_registered - @event.rsvps.collect(&:member)
  end

  def publish
    authorize @event
    return if @event.published? # don't publish it twice

    @event.update!(status: :published)

    # TODO: EventNotifier.after_publish(@event)
    flash[:notice] = t('events.publish_message', title: @event.title)
    redirect_to @event
  end

  # POST /units/:id/events/bulk_publish
  def bulk_publish
    event_ids = params[:event_ids]
    events    = Event.find(event_ids)

    events.each do |event|
      event.update!(status: :published)
    end

    # TODO: EventNotifier.after_bulk_publish(@unit, events)
    flash[:notice] = t("events.index.bulk_publish.success_message")

    redirect_to unit_events_path(@unit)
  end

  # GET /units/:unit_id/events/:id/rsvp
  # this is a variation on the 'show' action that swaps
  # out the RSVP panel on the modal with a form where users
  # can add/user their RSVPs.
  # TODO: is there a better, more RESTful way of doing this?
  def edit_rsvps
    @unit = Unit.find(params[:unit_id])
    @event = Event.find(params[:event_id])
    @event_view = EventView.new(@event)
    @current_member = @unit.membership_for(current_user)

    render "show"
  end

  # POST /units/:unit_id/events/:id/rsvp
  def create_or_update_rsvps
    note = params[:note]
    params[:event][:members].each do |member_id, values|
      response = values[:event_rsvp][:response]
      rsvp = @event.rsvps.create_with(
        response: response,
        note: note,
        respondent: @current_member
      ).find_or_create_by!(unit_membership_id: member_id)

      rsvp.update!(response: response, respondent: @current_member, note: note)
      # EventNotifier.send_rsvp_confirmation(rsvp)
    end

    @unit = @event.unit
    @current_member = @unit.membership_for(current_user)
    @current_family = @current_member.family
  end

  # GET cancel
  # display cancel dialog where user confirms cancellation and where
  # notification options are chosen
  def cancel
    find_unit
    find_event
  end

  # POST cancel
  # actually cancel the event and send out notifications
  def perform_cancellation
    find_unit
    find_event
    ap @event
    @event.status = :cancelled
    return unless @event.save!

    flash[:notice] = t("events.show.cancel.confirmation", event_title: @event.title)
    redirect_to unit_events_path(@unit)
  end

  # this override is needed to pass the membership instead of the user
  # as the object to be evaluated in Pundit policies
  def pundit_user
    @current_member
  end

  private

  def build_prototype_event
    @event = @unit.events.new(
      starts_at: 28.days.from_now,
      ends_at: 28.days.from_now
    )

    @event.starts_at = @event.starts_at.change({ hour: 10 }) # default starts at 10 AM
    @event.ends_at   = @event.ends_at.change({ hour: 16 }) # default ends at 4 PM
    @event_view = EventView.new(@event)
    @member_rsvps = @current_member.event_rsvps
  end

  # we don't guarantee that @unit is populated, hence...
  # @display_unit is used for global nav and other common
  # elements where unit is needed
  #
  # ^ kludge alert...this whole @unit / @current_unit thing needs to be undone...it sucks

  # for index, new, and create
  # rubocop:disable Style/SymbolArray
  def find_unit
    @current_unit = Unit.includes(
      :setting_objects,
      unit_memberships: [:user, :parent_relationships, :child_relationships]
    ).find(params[:unit_id])
    # @current_member = @unit.membership_for(current_user)
    @unit = @current_unit
    @current_member = @unit.membership_for(current_user)
  end
  # rubocop:enable Style/SymbolArray

  # for show, edit, update, destroy...important that @unit
  # is *not* set for those actions
  def find_event
    @event = Event.includes(:event_rsvps).find(params[:id] || params[:event_id])
    @current_unit = @event.unit
    @current_member = @current_unit.membership_for(current_user)
    @presenter = EventPresenter.new(event: @event, current_user: current_user)
  end

  # permitted parameters
  # rubocop:disable Metrics/MethodLength
  def event_params
    params.require(:event).permit(
      :title,
      :event_category_id,
      :location,
      :address,
      :description,
      :short_description,
      :requires_rsvp,
      :starts_at_date,
      :starts_at_time,
      :ends_at_date,
      :ends_at_time,
      :repeats_until,
      :departs_from,
      :status
    )
  end
  # rubocop:enable Metrics/MethodLength

  def event_set_datetimes
    event_set_start
    event_set_end
  end

  def event_set_start
    return unless params[:starts_at_d] && params[:starts_at_t]

    @event.starts_at = ScoutplanUtilities.compose_datetime(
      params[:starts_at_d],
      params[:starts_at_t]
    ).utc
  end

  def event_set_end
    return unless params[:ends_at_d] && params[:ends_at_t]

    @event.ends_at = ScoutplanUtilities.compose_datetime(
      params[:ends_at_d],
      params[:ends_at_t]
    ).utc
  end

  def set_time_zone(&block)
    Time.use_zone(@current_unit.settings(:locale).time_zone, &block)
  end
end
# rubocop:enable Metrics/ClassLength
