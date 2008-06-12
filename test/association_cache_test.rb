require File.dirname(__FILE__) + '/helper'
require File.dirname(__FILE__) + '/../init'

include ActiveRecord::AssociationCache

class AssociationCacheTest < ActiveRecordTestCase

  def setup
    Cache.clear!
  end
  
  def test_uncached_belongs_to
    User.belongs_to :account
    Account.has_many :users

    veggies = Account.create!(:name => 'veggies')
    carrot = veggies.users.create!(:name => 'carrot')
    carrot.reload

    assert_equal(veggies, carrot.account)
  end

  def test_cached_belongs_to
    User.belongs_to :account, :cached => true
    Account.has_many :users
    assert_equal(0, Cache.hits)

    veggies = Account.create!(:name => 'veggies')
    carrot = veggies.users.create!(:name => 'carrot')
    carrot.reload

    assert_equal(0, Cache.hits)
    assert_equal(veggies, carrot.account) # loads cache
    
    assert_equal(0, Cache.hits)
    
    carrot.reload
    assert_equal(veggies, carrot.account) # should get from cache
    assert_equal(1, Cache.hits)    
  end
  
  def test_uncached_has_many
    User.belongs_to :account
    Account.has_many :users

    veggies = Account.create!(:name => 'veggies')
    veggies.users.create!(:name => 'carrot')
    veggies.users.create!(:name => 'parsnip')
    veggies.reload
 
    assert_equal(2, veggies.users.to_a.size)
  end
  
  def test_cached_has_many_with_none_in_cache
    User.belongs_to :account
    Account.has_many :users, :cached => true
    
    veggies = Account.create!(:name => 'veggies')
    veggies.users.create!(:name => 'carrot')
    veggies.users.create!(:name => 'parsnip')
    veggies.reload 

    assert_equal(0, Cache.hits)
    assert_equal(0, Cache.misses)

    assert_equal(2, veggies.users.to_a.size)
    
    assert_equal(0, Cache.hits)
    assert_equal(2, Cache.misses)
    
    veggies.reload
    Cache.reset_counters!
    
    assert_equal(2, veggies.users.to_a.size)
    
    assert_equal(2, Cache.hits)
    assert_equal(0, Cache.misses)    
  end  

  def test_cached_has_many_with_one_in_cache
    User.belongs_to :account
    Account.has_many :users, :cached => true

    veggies = Account.create!(:name => 'veggies')
    carrot = veggies.users.create!(:name => 'carrot')
    Cache.put(carrot.cache_key, carrot)
    
    veggies.users.create!(:name => 'parsnip')
    veggies.reload 

    assert_equal(1, Cache.keys.size)
    assert_equal(0, Cache.hits)
    assert_equal(0, Cache.misses)

    assert_equal(2, veggies.users.to_a.size)
    
    assert_equal(2, Cache.keys.size)
    assert_equal(1, Cache.hits)
    assert_equal(1, Cache.misses)
    
    veggies.reload
    Cache.reset_counters!
    
    assert_equal(2, veggies.users.to_a.size)
    
    assert_equal(2, Cache.keys.size)
    assert_equal(2, Cache.hits)
    assert_equal(0, Cache.misses)    
  end
end

module Cache
  def self.get(key, expiry = 0)
    @cache ||= {}
    if value = @cache[key]
      @hits ||= 0; @hits += 1
      return value
    else
      @misses ||= 0; @misses += 1
    end
    
    value = yield
    @cache[key] = value
  end

  def self.put(key, value, expiry = 0)
    @cache ||= {}
    @cache[key] = value
  end

  def self.get_multiple(keys)
    @cache ||= {}
    results = keys.map { |key| @cache[key] }.compact
    @misses ||= 0; @misses += keys.size - results.size
    @hits ||= 0; @hits += results.size
    results
  end
  
  def self.cached?(key)
    @cache ||= {}
    @cache[key]
  end

  def self.keys
    (@cache || {}).keys
  end

  def self.clear!
    @cache = {}
    reset_counters!
  end

  def self.reset_counters!
    @hits = 0
    @misses = 0
  end
  
  def self.hits
    @hits || 0
  end

  def self.misses
    @misses || 0
  end
end
