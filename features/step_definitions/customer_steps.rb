World(FixtureAccess)
require File.expand_path(File.join(File.dirname(__FILE__), "..", "support", "paths"))

Given /^I am not logged in$/ do
  visit '/logout'
  response.should contain(/logged out/i)
end

Given /^I am logged in as (.*)?$/ do |who|
  is_admin = false
  case who
  when /nonsubscriber/
    @customer = customers(:tom)
  when /subscriber/
    @customer = customers(:tom)
    make_subscriber!(@customer)
  when /box ?office manager/i
    @customer = customers(:boxoffice_manager)
    is_admin = true
  when /box ?office/i
    @customer = customers(:boxoffice_user)
    is_admin = true
  else
    @customer = customers(:generic_customer)
  end
  visit login_path
  fill_in 'login', :with => @customer.login
  fill_in 'password', :with => 'pass'
  click_button 'Login'
  response.should contain(Regexp.new("Welcome,.*#{@customer.first_name}"))
  response.should have_selector('div[id=customer_quick_search].adminField') if is_admin
end
