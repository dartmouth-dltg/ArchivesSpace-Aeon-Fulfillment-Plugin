require 'aspace_logger'
require_relative "mixins/dartmouth_aeon_helpers"

class AeonRecordMapper

    include DartmouthAeonHelpers

    @@mappers = {}

    attr_reader :record, :container_instances

    def initialize(record_json)
        @logger = Logger.new($stderr)
        @record = aeon_helper_get_record(record_json['uri'])
        @container_instances = find_container_instances(record_json || {})
    end

    def self.register_for_record_type(type)
        @@mappers[type] = self
    end

    def self.mapper_for(record)
        logger = Logger.new($stderr)
        if @@mappers.has_key?(record.class)
            @@mappers[record.class].new(record)
        else
            logger.info("Aeon Fulfillment Plugin") { "This ArchivesSpace object type (#{record.class}) is not supported by this plugin." }
            raise
        end
    end

    def repo_code
        ASUtils.json_parse(self.record['json'])['repository']['_resolved']['repo_code'].downcase
    end

    def repo_settings
        AppConfig[:aeon_fulfillment][self.repo_code] || {}
    end

    def user_defined_fields
        mappings = {}

        if (udf_setting = self.repo_settings[:user_defined_fields])
            if (user_defined_fields = (ASUtils.json_parse(self.record['json']) || {})['user_defined'])

                # Determine if the list is a whitelist or a blacklist of fields.
                # If the setting is just an array, assume that the list is a
                # whitelist.
                if udf_setting == true
                    # If the setting is set to "true", then all fields should be
                    # pulled in. This is implemented as a blacklist that contains
                    # 0 values.
                    is_whitelist = false
                    fields = []

                    @logger.debug("Aeon Fulfillment Plugin") { "Pulling in all user defined fields" }
                else
                    if udf_setting.is_a?(Array)
                        is_whitelist = true
                        fields = udf_setting
                    else
                        list_type = udf_setting[:list_type]
                        is_whitelist = (list_type == :whitelist) || (list_type == 'whitelist')
                        fields = udf_setting[:values] || udf_setting[:fields] || []
                    end

                    list_type_description = is_whitelist ? 'Whitelist' : 'Blacklist'
                    @logger.debug("Aeon Fulfillment Plugin") { ":allow_user_defined_fields is a #{list_type_description}" }
                    @logger.debug("Aeon Fulfillment Plugin") { "User Defined Field #{list_type_description}: #{fields}" }
                end

                user_defined_fields.each do |field_name, value|
                    if (is_whitelist ? fields.include?(field_name) : fields.exclude?(field_name))
                        mappings["user_defined_#{field_name}"] = value
                    end
                end
            end
        end

        mappings
    end

    def unrequestable_display_message
        if !(self.repo_settings)
            return "";
        end

        if !self.requestable_based_on_archival_record_level?
            if (message = self.repo_settings[:disallowed_record_level_message])
                return message
            else
                return "Not requestable"
            end
        elsif !self.record_has_top_containers?
            if (message = self.repo_settings[:no_containers_message])
                return message
            else
                return "No requestable containers"
            end
        elsif self.record_has_restrictions?
            if (message = self.repo_settings[:restrictions_message])
                return message
            else
                return "Access restricted"
            end
        end
        return ""
    end
    
    def configured?
        return true if self.repo_settings
    end

    # This method tests whether the button should be hidden. This determination is based
    # on the settings for the repository and defaults to false.
    def hide_button?
        # returning false to maintain the original behavior
        return false unless self.repo_settings

        if self.repo_settings[:hide_request_button]
            return true
        elsif (self.repo_settings[:hide_button_for_accessions] == true && record.is_a?(Accession))
            return true
        elsif self.requestable_based_on_archival_record_level? == false
            return true
        elsif self.record_has_top_containers? == false
            return true
        elsif self.record_has_restrictions? == true
            return true
        end
        return false
    end

    def record_has_top_containers?
        return record.is_a?(Container) || self.container_instances.any?
    end

    def record_has_restrictions?
        if (types = self.repo_settings[:hide_button_for_access_restriction_types])
            notes = (ASUtils.json_parse(record['json']) || []).select {|n| n['type'] == 'accessrestrict' && n.has_key?('rights_restriction')}
                                                .map {|n| n['rights_restriction']['local_access_restriction_type']}
                                                .flatten.uniq

            # hide if the record notes have any of the restriction types listed in config
            access_restrictions = true if (notes - types).length < notes.length

            # check each top container for restrictions
            # if all of them are unrequestable, we should hide the request button for this record
            has_requestable_container = false
            if (instances = self.container_instances)
                instances.each do |instance|
                    if (container = instance['sub_container'])
                        if (top_container = container['top_container'])
                            if (top_container_resolved = top_container['_resolved'])
                                tc_has_restrictions = (top_container_resolved['active_restrictions'] || [])
                                    .map{ |ar| ar['local_access_restriction_type'] }
                                    .flatten.uniq
                                    .select{ |ar| types.include?(ar)}
                                    .any?
                                if tc_has_restrictions == false
                                    has_requestable_container = true
                                end
                            end
                        end
                    end
                end
            end

            return access_restrictions || !has_requestable_container
        end

        return false
    end

    # Determines if the :requestable_archival_record_levels setting is present
    # and excludes the 'level' property of the current record. This method is
    # not used by this class, because not all implementations of "abstract_archival_object"
    # have a "level" property that uses the "archival_record_level" enumeration.
    def requestable_based_on_archival_record_level?
        if (req_levels = self.repo_settings[:requestable_archival_record_levels])
            is_whitelist = false
            levels = []

            # Determine if the list is a whitelist or a blacklist of levels.
            # If the setting is just an array, assume that the list is a
            # whitelist.
            if req_levels.is_a?(Array)
                is_whitelist = true
                levels = req_levels
            else
                list_type = req_levels[:list_type]
                is_whitelist = (list_type == :whitelist) || (list_type == 'whitelist')
                levels = req_levels[:values] || req_levels[:levels] || []
            end

            list_type_description = is_whitelist ? 'Whitelist' : 'Blacklist'
            @logger.debug("Aeon Fulfillment Plugin") { ":requestable_archival_record_levels is a #{list_type_description}" }
            @logger.debug("Aeon Fulfillment Plugin") { "Record Level #{list_type_description}: #{levels}" }

            # Determine the level of the current record.
            level = ''
            if ASUtils.json_parse(self.record['json'])
                level = ASUtils.json_parse(self.record['json'])['level'] || ''
            end

            @logger.debug("Aeon Fulfillment Plugin") { "Record's Level: \"#{level}\"" }

            # If whitelist, check to see if the list of levels contains the level.
            # Otherwise, check to make sure the level is not in the list.
            return is_whitelist ? levels.include?(level) : levels.exclude?(level)
        end

        true
    end

    def log_record?
        return self.repo_settings[:log_records] == true
    end


    # Pulls data from the contained record
    def map
        mappings = []
        if self.container_instances && self.container_instances.count > 1
            self.container_instances.each do |inst, idx|
                mapping_hash = {}

                mapping_hash = mapping_hash
                    .merge(self.system_information)
                    .merge(self.json_fields(idx))
                    .merge(self.record_fields)
                    .merge(self.user_defined_fields)

                mappings << mapping_hash
            end
        else
            mapping_hash = {}

            mapping_hash = mapping_hash
                .merge(self.system_information)
                .merge(self.json_fields(nil))
                .merge(self.record_fields)
                .merge(self.user_defined_fields)

            mappings << mapping_hash
        end
    end


    # Pulls data from AppConfig and ASpace System
    def system_information
        mappings = {}

        mappings['SystemID'] =
            if (!self.repo_settings[:aeon_external_system_id].blank?)
                self.repo_settings[:aeon_external_system_id]
            else
                "ArchivesSpace"
            end

        return_url =
            if (!AppConfig[:frontend_proxy_prefix].blank?)
                AppConfig[:frontend_proxy_prefix]
            elsif (!AppConfig[:frontend_prefix].blank?)
                AppConfig[:frontend_prefix]
            else
                ""
            end

        mappings['ReturnLinkURL'] = "#{return_url}#{self.record['uri']}"

        mappings['ReturnLinkSystemName'] =
            if (!self.repo_settings[:aeon_return_link_label].blank?)
                self.repo_settings[:aeon_return_link_label]
            else
                "ArchivesSpace"
            end

        mappings['Site'] = self.repo_settings[:aeon_site_code] if self.repo_settings.has_key?(:aeon_site_code)

        mappings
    end

    # see udf exports - marc patches
    def date_strings_parse(date_string)
        # check if date ends with '-'
        # this is bad data entry, but fix it anyway
        if date_string.end_with?('-')
          date_string.chomp!('-')
        end
    
        date_parts = date_string.split('-')
        dp_length = date_parts.length
        date = nil
    
        if dp_length == 1
          date = Date.new(date_parts[0])
        elsif dp_length == 2
          date = Date.new(date_parts[0], date_parts[1])
        else
          date = Date.parse(date_string)
        end
    
        date
    
      end

    # see udf exports - marc patches    
    def calculate_date_expression(date, id_0)
        val = nil
        if date['expression'] && date['date_type'] != 'bulk'
            val = date['expression']
        elsif date['date_type'] == 'single'
            val = id_0 =~/doh/i ? date_strings_parse(date['begin']).strftime('%Y %B %-d') : date['begin']
        else
            if id_0 =~/doh/i
                val = "#{date_strings_parse(date['begin']).strftime('%Y %B %-d')} - #{date_strings_parse(date['end']).strftime('%Y %B %-d')}"
            else
                val = "#{date['begin']} - #{date['end']}"
            end
        end

    end

    # Pulls data from self.record
    def record_fields
        mappings = {}
        if log_record?
            @logger.debug("Aeon Fulfillment Plugin") { "Mapping Record: #{self.record}" }
        end

        mappings['identifier'] = self.record['ref_id']
        mappings['publish'] = self.record['publish']
        mappings['level'] = self.record['level']
        mappings['title'] = strip_mixed_content(self.record['title'])
        mappings['uri'] = self.record['uri']

        json = ASUtils.json_parse(self.record['json'])

        resource = json['resource']
        if resource
            resource_obj = resource['_resolved']
            if resource_obj
                id_0 = resource_obj['id_0']
                collection_id_components = [
                    id_0,
                    resource_obj['id_1'],
                    resource_obj['id_2'],
                    resource_obj['id_3']
                ]

                collection_id = collection_id_components
                    .reject {|id_comp| id_comp.blank?}
                    .join('-')

                if resource_obj['user_defined'] && resource_obj['user_defined']['enum_1']
                    enum = resource_obj['user_defined']['enum_1']
                    collection_name = I18n.t("enumerations.user_defined_enum_1.#{enum}")
                        .gsub(/Rauner/,'')
                        .gsub(/Manuscript/,'')
                        .gsub(/\-/,'')
                        .gsub(/Man\./,'')
                        .gsub(enum, '')
                        .strip
                    unless collection_name == ''
                        collection_name += ' '
                    end
                else 
                    collection_name = ''
                end
                
                mappings['collection_id'] = collection_name + collection_id
                mappings['collection_title'] = resource_obj['title']
            end
        end

        resolved_repository = json['repository']['_resolved']
        if resolved_repository
            mappings['repo_code'] = resolved_repository['repo_code']
            mappings['repo_name'] = resolved_repository['name']
        end

        if json['linked_agents']
            mappings['creators'] = json['linked_agents']
                .select { |cr| cr.present? && cr['role'] == 'creator'}
                .map { |cr| cr.strip }
                .join("; ")
        end

        if json['dates']
            mappings['date_expression'] = json['dates']
                                              .select{ |date| date['date_type'] == 'single' or date['date_type'] == 'inclusive'}
                                              .map{ |date| calculate_date_expression(date, id_0) }
                                              .join(';')
        end

        if json['notes']
            mappings['userestrict'] = json['notes']
                .select{ |n| n['type'] == 'userestrict'}
                .map { |note| note['subnotes'] }.flatten
                .select { |subnote| subnote['content'].present? and subnote['publish'] == true }
                .map { |subnote| subnote['content'] }.flatten
                .join("; ") 
        end
       
        mappings
    end


    # Pulls relevant data from the record's JSON property
    def json_fields(idx = nil)

        mappings = {}

        json = ASUtils.json_parse(self.record['json'])
        return mappings unless json

        lang_materials = json['lang_materials']
        if lang_materials
            mappings['language'] = lang_materials
                                    .select { |lm| lm['language_and_script'].present? and lm['language_and_script']['language'].present?}
                                    .map{ |lm| lm['language_and_script']['language'] }
                                    .flatten
                                    .join(";")
        end

        language = json['language']
        if language
            mappings['language'] = language
        end

        notes = json['notes']
        if notes
            mappings['physical_location_note'] = notes
                .select { |note| note['type'] == 'physloc' and note['content'].present? and note['publish'] == true }
                .map { |note| note['content'] }
                .flatten
                .join("; ")

            mappings['accessrestrict'] = notes
                .select { |note| note['type'] == 'accessrestrict' and note['subnotes'].present? }
                .map { |note| note['subnotes'] }
                .flatten
                .select { |subnote| subnote['content'].present? and subnote['publish'] == true}
                .map { |subnote| subnote['content'] }
                .reject { |content| content.match?(/Unrestricted/i) }
                .flatten
                .join("; ")
        end

        if json['dates']
            json['dates']
                .select { |date| date['expression'].present? }
                .group_by { |date| date['label'] }
                .each { |label, dates|
                    mappings["#{label}_date"] = dates
                        .map { |date| date['expression'] }
                        .join("; ")
                }
        end

        if json['linked_agents']
            mappings['creators'] = json['linked_agents']
                .select { |l| l['role'] == 'creator' && l['_resolved'] }
                .map { |l| l['_resolved']['names'] }.flatten
                .select { |n| n['is_display_name'] == true}
                .map { |n| n['sort_name']}
                .join("; ")
        end

        if json['rights_statements']
            mappings['rights_type'] = json['rights_statements'].map{ |r| r['rights_type']}.uniq.join(';')
        end

        digital_instances = json['instances'].select { |instance| instance['instance_type'] == 'digital_object'}
        if (digital_instances.any?)
            mappings["digital_objects"] = digital_instances.map{|d| d['digital_object']['ref']}.join(';')
        end

        mappings['restrictions_apply'] = self.record['custom_restrictions_u_sbool'].nil? ? json['restrictions_apply'] : self.record['custom_restrictions_u_sbool'].first
        mappings['display_string'] = json['display_string']

        instances = self.container_instances
        return mappings unless instances

        instance = idx.nil? ? instances[0] : instances[idx]

        mappings["instance_is_representative"] = instance['is_representative']
        mappings["instance_last_modified_by"] = instance['last_modified_by']
        mappings["instance_instance_type"] = instance['instance_type']
        mappings["instance_created_by"] = instance['created_by']

        container = instance['sub_container']
        return mappings unless container

        mappings["instance_container_grandchild_indicator"] = container['indicator_3']
        mappings["instance_container_child_indicator"] = container['indicator_2']
        mappings["instance_container_grandchild_type"] = container['type_3']
        mappings["instance_container_child_type"] = container['type_2']
        mappings["instance_container_last_modified_by"] = container['last_modified_by']
        mappings["instance_container_created_by"] = container['created_by']

        top_container = container['top_container']
        return mappings unless top_container

        mappings["instance_top_container_ref"] = top_container['ref']

        top_container_resolved = top_container['_resolved']
        return mappings unless top_container_resolved

        mappings["instance_top_container_long_display_string"] = top_container_resolved['long_display_string']
        mappings["instance_top_container_last_modified_by"] = top_container_resolved['last_modified_by']
        mappings["instance_top_container_display_string"] = top_container_resolved['display_string']
        mappings["instance_top_container_restricted"] = top_container_resolved['restricted']
        mappings["instance_top_container_created_by"] = top_container_resolved['created_by']
        mappings["instance_top_container_indicator"] = top_container_resolved['indicator']
        mappings["instance_top_container_barcode"] = top_container_resolved['barcode']
        mappings["instance_top_container_type"] = top_container_resolved['type']
        mappings["instance_top_container_uri"] = top_container_resolved['uri']

        if (top_container_resolved['container_locations'])
            mappings["instance_top_container_location_note"] = top_container_resolved['container_locations'].map{ |l| l['note']}.join{';'}
        end

        mappings["requestable"] = (top_container_resolved['active_restrictions'] || [])
            .map{ |ar| ar['local_access_restriction_type'] }
            .flatten.uniq
            .select{ |ar| (self.repo_settings[:hide_button_for_access_restriction_types] || []).include?(ar)}
            .empty?

        locations = top_container_resolved["container_locations"]
        if locations.any?
            location_id = locations.sort_by { |l| l["start_date"]}.last()["ref"]
            location = aeon_helper_get_location(location_id)
            mappings["instance_top_container_location"] = location['title']
            mappings["instance_top_container_location_id"] = location_id
            mappings["instance_top_container_location_building"] = location['building']
        elsif json['id_0'] && json['id_0'].match?(/\d{6}/i)
            mappings["instance_top_container_location"] = 'Individual Manuscript'
        else
            mappings["instance_top_container_location"] = 'No Location Found'
        end

        collection = top_container_resolved['collection']
        if collection
            mappings["instance_top_container_collection_identifier"] = collection
                .select { |c| c['identifier'].present? }
                .map { |c| c['identifier'] }
                .join("; ")

                mappings["instance_top_container_collection_display_string"] = collection
                .select { |c| c['display_string'].present? }
                .map { |c| c['display_string'] }
                .join("; ")
        end

        series = top_container_resolved['series']
        if series
            mappings["instance_top_container_series_identifier"] = series
                .select { |s| s['identifier'].present? }
                .map { |s| s['identifier'] }
                .join("; ")

                mappings["instance_top_container_series_display_string"] = series
                .select { |s| s['display_string'].present? }
                .map { |s| s['display_string'] }
                .join("; ")

        end

        mappings
    end

    # Grabs a list of instances from the given jsonmodel, ignoring any digital object
    # instances. If the current jsonmodel does not have any top container instances, the
    # method will recurse up the record's resource tree, until it finds a record that does
    # have top container instances, and will pull the list of instances from there.
    def find_container_instances (record_json)
        
        current_uri = record_json['uri']
        
        @logger.info("Aeon Fulfillment Plugin") { "Checking \"#{current_uri}\" for Top Container instances..." }
        if log_record?
            @logger.debug("Aeon Fulfillment Plugin") { "#{record_json.to_json}" }
        end

        instances = record_json['instances']
            .reject { |instance| instance['digital_object'] }

        if instances.any?
            @logger.info("Aeon Fulfillment Plugin") { "Top Container instances found" }
            return instances
        end

        # If we're in top container mode, we can skip this step, 
        # since we only want to present containers associated with the current record.
        if (!self.repo_settings[:top_container_mode])
            parent_uri = ''

            if record_json['parent'].present?
                parent_uri = record_json['parent']['ref']
                parent_uri = record_json['parent'] unless parent_uri.present?
            elsif record_json['resource'].present?
                parent_uri = record_json['resource']['ref']
                parent_uri = record_json['resource'] unless parent_uri.present?
            end

            if parent_uri.present?
                @logger.debug("Aeon Fulfillment Plugin") { "No Top Container instances found. Checking parent. (#{parent_uri})" }
                parent = aeon_helper_get_record(parent_uri)
                parent_json = parent['json']
                return find_container_instances(parent_json)
            end
        end

        @logger.debug("Aeon Fulfillment Plugin") { "No Top Container instances found." }

        []
    end

    protected :json_fields, :record_fields, :system_information,
              :requestable_based_on_archival_record_level?,
              :find_container_instances, :user_defined_fields
end
