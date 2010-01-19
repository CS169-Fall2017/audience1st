class Vouchertype < ActiveRecord::Base
  has_many :valid_vouchers
  has_many :vouchers
  has_many :showdates, :through => :valid_vouchers
  serialize :included_vouchers, Hash

  validates_length_of :name, :within => 3..40, :message => "Voucher type name must be between 3 and 40 characters"
  validates_numericality_of :price
  validates_presence_of(:account_code, :if => lambda { |v| v.price != 0 },
                        :message => "Vouchers that create revenue must have an account code")
  validates_inclusion_of :offer_public, :in => -1..2, :message => "Invalid specification of who may purchase"
  validates_inclusion_of :category, :in => [:revenue, :comp, :subscriber, :bundle, :nonticket]
  # Vouchertypes whose price is zero must NOT be available
  # to subscribers or general public
  validates_exclusion_of(:offer_public, :in => [1,2],
                         :if => lambda { |v| v.price.zero? },
                         :message => "Zero-price vouchers can only be sold
                                        by box office or external reseller")

  # Subscription vouchertypes shouldn't be available for walkup sale,
  # since we need to capture the address
  validate :subscriptions_shouldnt_be_walkups
  # Subscription vouchertypes' validity period must be < 2 years
  validate :subscriptions_valid_at_most_2_years
  # Free vouchers must not be subscriber vouchers or offered to public
  validate :restrict_if_free

  protected
  def subscriptions_shouldnt_be_walkups
    if walkup_sale_allowed? && subscription?
      errors.add_to_base "Subscription vouchers can't be sold via
                walkup sales screen, since address must be captured."
    end
  end
  
  def subscriptions_valid_at_most_2_years
    if subscription? && (expiration_date - valid_date >= 2.years)
      end_date = Time.local(Time.now.year, Option.value(:season_start_month),
                            Option.value(:season_start_day)) - 1.day
      errors.add_to_base "Maximum validity period of subscription vouchers
        is 2 years minus 1 day. It's suggested you make the expiration date
        the same as your season end date, which you set in Options
        as #{end_date.to_formatted_s(:month_day_only)}."
    end
  end

  def restrict_if_free
    if price.zero?
      if offer_public == ANYONE
        errors.add_to_base "Free vouchers can't be available to public"
      elsif category == 'subscription'
        errors.add_to_base "Free vouchers can't qualify recipient as Subscriber"
      end
    end
  end
  
  # Functions that determine visibility of a voucher type to particular
  # customers
  BOXOFFICE = 0
  SUBSCRIBERS = 1
  ANYONE = 2
  EXTERNAL = -1

  @@offer_to = [["Box office use only", BOXOFFICE],
                ["Subscribers may purchase",SUBSCRIBERS],
                ["Anyone may purchase", ANYONE],
                ["Sold by external reseller", EXTERNAL]]

  public
  
  def self.offer_to
    @@offer_to
  end

  def bundle? ; category == :bundle ; end
  def comp? ; category == :comp ; end

  def visibility
    @@offer_to.rassoc(self.offer_public).first rescue "Error (#{self.offer_public})"
  end

  def self.comp_vouchertypes
    Vouchertype.find(:all, :conditions => ['category = ?', :comp],
      :order => 'name')
  end

  def self.nonbundle_vouchertypes
    Vouchertype.find(:all, :conditions => ["category != ?", :bundle],
                     :order => 'price', :order => 'expiration_date DESC')
  end

  def self.bundle_vouchertypes
    Vouchertype.find(:all, :conditions => ["category = ?", :bundle],
                     :order => 'price', :order => 'expiration_date DESC')
  end

  def self.subscription_vouchertypes
    Vouchertype.find(:all,
      :conditions => ["category = ? AND subscription = ?", :bundle, true], :order => 'expiration_date DESC')
  end

  def self.revenue_vouchertypes
    Vouchertype.find(:all, :conditions => ["category = ?", :revenue], :order => 'expiration_date DESC')
  end

  def self.nonticket_vouchertypes
    Vouchertype.find(:all, :conditions => ["category = ?", :nonticket], :order => 'expiration_date DESC')
  end

  def self.zero_cost_vouchertypes
    Vouchertype.find(:all, :conditions => ["price = ?", 0.0], :order => 'expiration_date DESC')
  end

  def self.find_products(args={})
    restrict = []
    arglist = []
    case args[:for_purchase_by]
    when :subscribers
      restrict << "(offer_public = #{SUBSCRIBERS} OR offer_public = #{ANYONE})"
    when :boxoffice
      restrict << "offer_public = #{BOXOFFICE}"
    when :external
      restrict << "offer_public = #{EXTERNAL}"
    else
      restrict << "offer_public = #{ANYONE}"
    end
    if (created_on = args[:since])
      restrict << "created_on >= ?"
      arglist << created_on
    end
    case args[:type]
    when :subscription
      restrict << "category = 'bundle' AND subscription = 1"
      restrict << "#{Time.db_now} BETWEEN bundle_sales_start AND bundle_sales_end" unless
        (args[:for_purchase_by] == :boxoffice || args[:ignore_cutoff])
    when :bundle
      restrict << "category = 'bundle'"
      restrict << "#{Time.db_now} BETWEEN bundle_sales_start AND bundle_sales_end" unless
        (args[:for_purchase_by] == :boxoffice || args[:ignore_cutoff])
    end
    if args.has_key?(:walkup)
      case args[:walkup]
      when true
        restrict << "walkup_sale_allowed = 1"
      when false
        restrict << "walkup_sale_allowed = 0"
      end
    end
    arglist.unshift(restrict.join(" AND "))
    Vouchertype.find(:all, :conditions => arglist)
  end

  def valid_as_of?(date)
    d = date.to_time
    d >= valid_date && d <= expiration_date
  end

  def valid_now?
    valid_as_of?(Time.now)
  end

  def valid_for_season?(season = Time.now.year)
    expiration_date <= Time.now.at_end_of_season(season)  &&
      valid_date > Time.now.at_beginning_of_season(season - 1)
  end
  
  def get_included_vouchers
    if self.bundle?
      hsh = self.included_vouchers
      numeric_hsh = Hash.new
      # convert everthing to ints (stored as strings)
      hsh.each_pair { |k,v| numeric_hsh[k.to_i || 0] = (v.to_i || 0) }
      numeric_hsh
    else
      {}
    end
  end

  def name_with_price
    self.name + sprintf(" - $%0.2f", self.price)
  end

  def self.walkup_vouchertypes
    Vouchertype.find(:all, :conditions => ['subscription = ? AND walkup_sale_allowed = ?', false, true])
  end
  
  # Override content_columns to not display included vouchers (since
  # requires special code)

  def self.content_columns
    c = super
    c.delete_if { |x| x.name.match('included_vouchers') }
    c
  end

end
