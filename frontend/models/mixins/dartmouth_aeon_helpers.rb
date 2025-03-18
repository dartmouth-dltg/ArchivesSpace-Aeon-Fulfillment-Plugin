require 'nokogiri'

module DartmouthAeonHelpers

  # ripped directly from ManipulateNode class
  # strips all xml markup; used for things like titles.
  def strip_mixed_content(in_text)
    return if !in_text

    # Don't fire up nokogiri if there's no mixed content to parse
    unless in_text.include?("<")
      return in_text
    end

    in_text = in_text.gsub(/ & /, ' &amp; ')
    @frag = Nokogiri::XML.fragment(in_text)

    @frag.content
  end

  def aeon_helper_get_record(uri)
    resolve = ['ancestors:id', 'top_container_uri_u_sstr:id']
    response = JSONModel::HTTP.post_form("/search/records", {"uri[]" =>  [uri], "resolve[]" => resolve})
    results = ASUtils.json_parse(response.body)['results']
    if results.count == 1
      results[0]
    else
      {}
    end
  end

  def aeon_helper_get_location(location_id)
    response = JSONModel::HTTP.get_json("#{location_id}")
  end
  
end
