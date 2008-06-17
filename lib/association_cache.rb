module ActiveRecord
  module AssociationCache

    def self.active?
      @caching_active
    end
    
    def self.active=(on)
      @caching_active = on
    end
    
    def self.extended(base)
      class << base
        alias_method_chain :belongs_to, :cache
        alias_method_chain :has_and_belongs_to_many, :cache
      end
    end

    def belongs_to_with_cache(*args)
      options = args.extract_options!
      cached = options.delete(:cached)
      association_name = args.first

      belongs_to_without_cache(association_name, options)

      if cached
        association_id_name = options[:foreign_key] || "#{association_name}_id"
        association_class = options[:class_name] || association_name.to_s.classify

        class_eval <<-END
          def #{association_name}_with_cache
            if ActiveRecord::AssociationCache.active?
              id = #{association_id_name}
              Cache.get("#{association_class}::\#{id}") do
                #{association_name}_without_cache
              end
            else
              #{association_name}_without_cache
            end
          end
        END

        alias_method_chain :"#{association_name}", :cache
      end
    end

    def has_many(association_id, options = {}, &extension)
      cached = options.delete(:cached)
      reflection = create_has_many_reflection(association_id, options, &extension)

      configure_dependency_for_has_many(reflection)

      if options[:through]
        collection_reader_method(reflection, ::ActiveRecord::Associations::HasManyThroughAssociation)
        collection_accessor_methods(reflection, ::ActiveRecord::Associations::HasManyThroughAssociation, false)
      else
        add_multiple_associated_save_callbacks(reflection.name)
        add_association_callbacks(reflection.name, reflection.options)
        collection_accessor_methods(reflection,
          cached ? ::ActiveRecord::Associations::CachedHasManyAssociation :
                      ::ActiveRecord::Associations::HasManyAssociation)
      end
    end
    
    def has_and_belongs_to_many_with_cache(association_id, options = {}, &extension)
      cached = options.delete(:cached)
      
      return has_and_belongs_to_many_without_cache(association_id, options, &extension) unless cached
      
      reflection = create_has_and_belongs_to_many_reflection(association_id, options, &extension)

      add_multiple_associated_save_callbacks(reflection.name)
      collection_accessor_methods(reflection, 
        ::ActiveRecord::Associations::CachedHasAndBelongsToManyAssociation)

      # Don't use a before_destroy callback since users' before_destroy
      # callbacks will be executed after the association is wiped out.
      old_method = "destroy_without_habtm_shim_for_#{reflection.name}"
      class_eval <<-end_eval unless method_defined?(old_method)
        alias_method :#{old_method}, :destroy_without_callbacks
        def destroy_without_callbacks
          #{reflection.name}.clear
          #{old_method}
        end
      end_eval

      add_association_callbacks(reflection.name, options)
    end    
  end
end

ActiveRecord::Base.class_eval do
  extend ActiveRecord::AssociationCache
end

class ActiveRecord::Base
  class << self      
    def find_with_cache(*args)
      options = args.extract_options!

      if [:first, :all].include?(args.first)
        options[:select] = "#{quoted_table_name}.id"
        results = find(*(args << options)) # make faster like for collections
        if args.first == :all
          CacheHelper.retrieve_records(results.map(&:id), self)
        else
          CacheHelper.retrieve_records([results.id], self).first
        end
      else
        id = args.first
        Cache.get("#{name}::#{id}") do
          find(*(args << options))
        end      
      end
    end    
  end

  def cache!
    Cache.put(cache_key, self)    
  end
  
  def remove_from_cache
    Cache.delete(cache_key, self)    
  end
  
  def cache_key
    key_class = self.class
    while key_class.superclass != ActiveRecord::Base && key_class.superclass != Object
      key_class = key_class.superclass
    end
    "#{key_class.name}::#{self.id}"
  end
end

class CacheHelper
  class << self
    def retrieve_records(ids, klass)
      cache_keys = ids.map { |id| "#{klass.name}::#{id}" }
      record_hash = Cache.get_multiple(cache_keys)
      
      if record_hash.size < ids.size
        record_ids = record_hash.keys.map { |k| k.gsub(/.*::/, '').to_i}
        missing_record_ids = ids.select { |id| !record_ids.include?(id) }      
        missing_records = klass.find(:all, 
          :conditions => ["#{klass.quoted_table_name}.id in (?)", missing_record_ids])
          
        missing_records.each do |record|
          Cache.put(record.cache_key, record)
        end
        missing_records.each { |record| record_hash[record.cache_key] = record }
      end
      
      ids.collect { |id| record_hash["#{klass.name}::#{id}"] }
    end
  end
end

module ActiveRecord
  module Associations

    module AssociationHelper
      def select_ids(options)
        connection.select_all(
          construct_finder_sql_for_ids(options), "#{name} Loading ids")
      end
      
      def construct_finder_sql_for_ids(options)
        scope = scope(:find)
        sql = "SELECT #{quoted_table_name}.id FROM #{(scope && scope[:from]) || options[:from] || quoted_table_name} "

        add_conditions!(sql, options[:conditions], scope)

        add_group!(sql, options[:group], scope)
        add_order!(sql, options[:order], scope)
        add_lock!(sql, options, scope)

        return sanitize_sql(sql)
      end  
    end
    
    class CachedHasAndBelongsToManyAssociation < HasAndBelongsToManyAssociation
            
      include AssociationHelper
      
      def find(*args)
        options = args.extract_options!
      
        # If using a custom finder_sql, scan the entire collection.
        # The finder_sql condition is unchanged from the superclass definition
        if @reflection.options[:finder_sql]
          expects_array = args.first.kind_of?(Array)
          ids = args.flatten.compact.uniq
      
          if ids.size == 1
            id = ids.first.to_i
            record = load_target.detect { |r| id == r.id }
            expects_array ? [record] : record
          else
            load_target.select { |r| ids.include?(r.id) }
          end
        else
          conditions = "#{@finder_sql}"
      
          if sanitized_conditions = sanitize_sql(options[:conditions])
            conditions << " AND (#{sanitized_conditions})"
          end
      
          options[:conditions] = conditions
          options[:joins]      = @join_sql
          options[:readonly]   = finding_with_ambiguous_select?(options[:select] || @reflection.options[:select])
      
          if options[:order] && @reflection.options[:order]
            options[:order] = "#{options[:order]}, #{@reflection.options[:order]}"
          elsif @reflection.options[:order]
            options[:order] = @reflection.options[:order]
          end
      
          merge_options_from_reflection!(options)
      
          options[:select] = "#{@reflection.table_name}.id"
          # 
          # # Pass through args exactly as we received them.
          # args << options
          # @reflection.klass.find(*args)
      
          # Pass through args exactly as we received them.
          args << options
          ids = @reflection.klass.find(*args).map(&:id)
          CacheHelper.retrieve_records(ids, @reflection.klass)
        end
      end      
    end
    
    class CachedHasManyAssociation < HasManyAssociation
      include AssociationHelper
      
      def find(*args)
        options = args.extract_options!

        # If using a custom finder_sql, scan the entire collection.
        if @reflection.options[:finder_sql]
          expects_array = args.first.kind_of?(Array)
          ids           = args.flatten.compact.uniq.map(&:to_i)

          if ids.size == 1
            id = ids.first
            record = load_target.detect { |record| id == record.id }
            expects_array ? [ record ] : record
          else
            load_target.select { |record| ids.include?(record.id) }
          end
        else
          conditions = "#{@finder_sql}"
          if sanitized_conditions = sanitize_sql(options[:conditions])
            conditions << " AND (#{sanitized_conditions})"
          end
          options[:conditions] = conditions

          if options[:order] && @reflection.options[:order]
            options[:order] = "#{options[:order]}, #{@reflection.options[:order]}"
          elsif @reflection.options[:order]
            options[:order] = @reflection.options[:order]
          end

          merge_options_from_reflection!(options)

          # Go after ONLY the ids
          options = options.merge(:select => "#{@reflection.table_name}.id")

          # Pass through args exactly as we received them.
          args << options
                    
          unless options[:join] || (scope(:find) && scope(:find)[:join])
            # Doing it this way will cause complex joins to break, 
            # but its way faster then the else condition.
            ids = select_ids(options).map { |row| row["id"].to_i }
          else
            # More robust, but slower cause full active records objects
            # are instanciated.
            ids = @reflection.klass.find(*args).map(&:id)
          end

          CacheHelper.retrieve_records(ids, @reflection.klass)
        end
      end  
    end
  end
end
