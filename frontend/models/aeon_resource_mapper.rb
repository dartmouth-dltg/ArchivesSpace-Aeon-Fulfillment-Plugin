class AeonResourceMapper < AeonRecordMapper

    include DartmouthAeonHelpers

    register_for_record_type(Resource)

    def initialize(resource_json)
        super(resource_json)
    end

    # Override for AeonRecordMapper json_fields method.
    def json_fields(idx = nil)
        mappings = super

        json = ASUtils.json_parse(self.record['json'])
        return mappings unless json

        if json['repository_processing_note'] && json['repository_processing_note'].present?
            mappings['repository_processing_note'] = json['repository_processing_note']
        end

        resource_identifier = [ json['id_0'], json['id_1'], json['id_2'], json['id_3'] ]
        collection_id = resource_identifier
            .reject {|id_comp| id_comp.blank?}
            .join('-')

        if json['user_defined'] && json['user_defined']['enum_1']
            enum = json['user_defined']['enum_1']
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
        mappings['collection_title'] = strip_mixed_content(self.record['title'])

        mappings['ead_id'] = json['ead_id']
        mappings['ead_location'] = json['ead_location']
        mappings['finding_aid_title'] = json['finding_aid_title']
        mappings['finding_aid_subtitle'] = json['finding_aid_subtitle']
        mappings['finding_aid_filing_title'] = json['finding_aid_filing_title']
        mappings['finding_aid_date'] = json['finding_aid_date']
        mappings['finding_aid_author'] = json['finding_aid_author']
        mappings['finding_aid_description_rules'] = json['finding_aid_description_rules']
        mappings['resource_finding_aid_description_rules'] = json['resource_finding_aid_description_rules']
        mappings['finding_aid_language'] = json['finding_aid_language']
        mappings['finding_aid_sponsor'] = json['finding_aid_sponsor']
        mappings['finding_aid_edition_statement'] = json['finding_aid_edition_statement']
        mappings['finding_aid_series_statement'] = json['finding_aid_series_statement']
        mappings['finding_aid_status'] = json['finding_aid_status']
        mappings['finding_aid_note'] = json['finding_aid_note']
        mappings['restrictions_apply'] = self.record['custom_restrictions_u_sbool'].nil? ? json['restrictions'] : self.record['custom_restrictions_u_sbool'].first

        mappings
    end

end
