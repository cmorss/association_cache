module ActiveRecord
  module AssociationCache

    def self.extended(base)
      class << base
        alias_method_chain :belongs_to, :cache
      end
    end

    def belongs_to_with_cache(*args)
      options = args.extract_options!
      cached = options.delete(:cached)
      association_name = args.first

      belongs_to_without_cache(association_name, options)

      if cached
        association_id_name = options[:foreign_key_id] || "#{association_name}_id"
        association_class = options[:class_name] || association_name.to_s.classify

        class_eval <<-END
          def #{association_name}_with_cache
            id = #{association_id_name}
            Cache.get("#{association_class}::\#{id}") do
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
        collection_reader_method(reflection, HasManyThroughAssociation)
        collection_accessor_methods(reflection, HasManyThroughAssociation, false)
      else
        add_multiple_associated_save_callbacks(reflection.name)
        add_association_callbacks(reflection.name, reflection.options)
        collection_accessor_methods(reflection,
          cached ? ActiveRecord::Associations::CachedHasManyAssociation :
                      ActiveRecord::Associations::HasManyAssociation)
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  extend ActiveRecord::AssociationCache
end

class ActiveRecord::Base
  def cache_key
    "#{self.class.name}::#{self.id}"
  end
end

module ActiveRecord
  module Associations
    class CachedHasManyAssociation < HasManyAssociation
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
          
          unless options[:join]
            # Doing it this way will cause complex joins to break, 
            # but its way faster then the else condition.
            ids = select_ids(options).map { |row| row["id"].to_i }
          else
            # More robust, but slower cause full active records objects
            # are instanciated.
            ids = @reflection.klass.find(*args).map(&:id)
          end

          cache_keys = ids.map { |id| "#{@reflection.klass.name}::#{id}" }
          records = Cache.get_multiple(cache_keys)
          record_ids = records.map(&:id)

          missing_record_ids = ids.select { |id| !record_ids.include?(id) }

          missing_records = @reflection.klass.find(:all,
            :conditions => ['id in (?)', missing_record_ids])

          missing_records.each do |record|
            Cache.put(record.cache_key, record)
          end

          records.concat(missing_records)

          # Slow sort method. Use a hash for more goodness
          ids.collect { |id| records.detect { |r| r.id == id } }
        end
      end
      
      def select_ids(options)
        connection.select_all(
          construct_finder_sql_for_ids(options), "#{name} Loading ids")
      end
      
      def construct_finder_sql_for_ids(options)
        scope = scope(:find)
        sql = "SELECT #{quoted_table_name}.id FROM #{(scope && scope[:from]) || options[:from] || quoted_table_name} "

        add_joins!(sql, options, scope)
        add_conditions!(sql, options[:conditions], scope)

        add_group!(sql, options[:group], scope)
        add_order!(sql, options[:order], scope)
        add_lock!(sql, options, scope)

        return sanitize_sql(sql)
      end 
           
    end
  end
end
