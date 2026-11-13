# Runs depot.qnt's actions on the depot's pages and its intake job, and stands
# in for the locker controller the app calls.
class DepotDriver
  PARCELS = %w[p1 p2 p3].freeze
  COMPARTMENTS = [ 1, 2 ].freeze

  # +example+ is the RSpec example, which makes the requests.
  def initialize(example) = @example = example

  # What the stubbed LockerApi asks. The controller keeps or drops a
  # compartment's code, and times out for the one the step picked as offline.
  def register(number, code) = online(number) { @codes[number] = code }
  def revoke(number) = online(number) { @codes.delete(number) }

  def step(action, picks)
    @offline = picks["offline"]
    parcel = "/parcels/#{@ids.fetch(picks["p"])}" if picks["p"]
    case action
    when "init"
      @codes = {}
      COMPARTMENTS.each { FactoryBot.create(:compartment, number: _1) }
      @ids = PARCELS.to_h { [ _1, FactoryBot.create(:parcel, label: _1).id ] }
    when "assignParcel" then post "#{parcel}/assignment"
    when "release" then post "#{parcel}/release"
    when "withdraw" then post "#{parcel}/withdrawal"
    when "takeIn" then post "/intakes", manifest: Parcel.order(:id).pluck(:label).join("\n")
    when "runJob" then IntakeJob.perform_now(Intake.sole)
    end
  end

  # everDone is not here: the example names it in ignore:, as only the spec remembers it.
  def state
    parcels = Parcel.includes(:compartment).index_by(&:id)
    rows = IntakeRow.pluck(:parcel_id, :status).to_h
    { "place" => @ids.transform_values { place_of(parcels[_1]) },
      "live" => @codes.keys.to_set,
      "row" => @ids.transform_values { rows.fetch(_1, "") },
      "intake" => intake }
  end

  private
    def online(number)
      raise LockerApi::TimedOut if number == @offline

      yield
    end

    # A page answers with a redirect. Any other answer raises, so it fails the step by name.
    def post(path, **params)
      @example.post path, params: params
      raise "POST #{path} answered #{@example.response.status}" unless @example.response.redirect?
    end

    def place_of(parcel)
      if parcel.nil? then "Withdrawn"
      elsif parcel.collected_at then "Collected"
      elsif parcel.compartment then [ "In", parcel.compartment.number ]
      else "Waiting"
      end
    end

    def intake
      taken_in = Intake.first or return "none"
      taken_in.finished_at ? "finished" : "open"
    end
end
