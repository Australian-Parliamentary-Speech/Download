module PSSSourceXML

using ArgParse
using Cascadia
using ProgressMeter
using PSSUtils
using EzXML
using Dates
using Gumbo

#
# === Constants ===
#

const URL::AbstractString = "https://parlinfo.aph.gov.au/sitemap/sitemapindex.xml"

#
# === Types ===
# 

@enum SXMLHouse house senate
@enum SXMLSteps Step1 Step2 Step3 Step4 Step5 Step6 Step7

struct SXMLPaths
    base::AbstractString
    sitemaps::AbstractString
    xmls::AbstractString
    htmls::AbstractString
    interim::AbstractString
    log::AbstractString
end

function SXMLPaths(output::AbstractString, sxml_house::AbstractString)
    base = joinpath(output, "source_xml", sxml_house)
    sitemaps = joinpath(base, "sitemaps")
    xmls = joinpath(base, "xmls")
    htmls = joinpath(base, "htmls")
    interim = joinpath(base, "interim")
    log = joinpath(base, "logs")
    return SXMLPaths(base, sitemaps, xmls, htmls, interim, log)
end

function ArgParse.parse_item(::Type{SXMLHouse}, x::AbstractString)
    for v in instances(SXMLHouse)
        string(v) == x && return v
    end
end

#
# === Utility Functions ===
# 

function is_hansard_link(link::AbstractString, house::SXMLHouse)
    char = (string(house) == "house") ? "r" : "s"
    return occursin("hansard" * char, link)
end

function compare_links(url1::AbstractString, url2::AbstractString)
    pattern = r"%2F\d+%22"
    cleaned_url1 = replace(url1, pattern => "")
    cleaned_url2 = replace(url2, pattern => "")
    return cleaned_url1 == cleaned_url2
end

function find_query_from_url(url::AbstractString)
    pattern = r"query=([^;]+);"
    m = match(pattern, url)
    return m.captures[1]
end

function find_date_subsoup(soup)
    date = try
        subsoup = eachmatch(sel"div.twoBoxForm", soup)[2]
        div = eachmatch(sel"div.metaPadding", subsoup)[1]
        date_soup = eachmatch(sel"p.mdItem", div)[1]
        date = date_soup.children[1].text
    catch
        date = "N/A"
    end
    return date
end

#
# === CLI ===
# 

function get_args()
    s = ArgParseSettings()

    @add_arg_table! s begin
        "sxml_house"
        required = true
        arg_type = SXMLHouse
        help = "One of `" * join(string.(instances(SXMLHouse)), ", ") * "`"

        "--output", "-o"
        required = false
        arg_type = AbstractString
        default = "output"
        help = "Output directory, defaults to `output/`"

        "--should_compress", "-c"
        action = :store_true
        help = "Compress output"

        "--skip", "-s"
        action = :store_true
        help = "Skip processing, usually combined with -c to compress a completed run"
    end
    return parse_args(s; as_symbols=true)
end


#
# === Main ===
#

function run(; sxml_house::SXMLHouse, output::AbstractString, should_compress::Bool, skip::Bool)::Bool
    paths = SXMLPaths(output, string(sxml_house))
    success = true
    if !skip
        if isfile(paths.base * ".tar.zst")
            @info "Decompressing previous run..."
            decompress(paths.base * ".tar.zst", paths.base, clear=true)
        end
        mkpath(paths.base)
        mkpath(paths.sitemaps)
        mkpath(paths.xmls)
        mkpath(paths.htmls)
        mkpath(paths.interim)
        mkpath(paths.log)
        logger = get_logger(paths.log)
        success &= with_logger(logger) do
            run(Val(Step1); paths=paths, sxml_house=sxml_house)
        end
        success &= run(Val(Step1); paths=paths, sxml_house=sxml_house)
    end
    success &= run(Val(Step7); paths=paths, should_compress=should_compress)
    return success
end

function run(::Val{Step1}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    sitemaps_out = paths.sitemaps
    sitemaps = joinpath(paths.interim, "sitemaps.xml")
    download_file(URL, sitemaps; filetype="text/xml")
    xdoc = readxml(sitemaps)
    soup = root(xdoc)
    elems = elements(soup)
    if isfile(sitemaps) && length(readdir(sitemaps_out)) == length(elems)
        @info "Step 1 already completed as $(sitemaps_out) exists and is populated, skipping..."
    else
        @info "Running step 1: Downloading $(length(elems) - length(readdir(sitemaps_out))) sitemap XMLs..."
        @showprogress for (i, e) in enumerate(elems)
            e_file = joinpath(sitemaps_out, "$(i).xml")
            link = elements(e)[1].content
            download_file(link, e_file; filetype="text/xml")
        end
    end
    return run(Val(Step2); paths=paths, sxml_house=sxml_house)
end

function run(::Val{Step2}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    urls_out = paths.interim
    date = string(today())
    urls = joinpath(urls_out, date * "_urls.txt")
    sitemaps = readdir(paths.sitemaps, join=true)
    if isfile(urls) && length(readlines(urls)) > 0
        @info "Step 2 already completed as $(urls) exists and is populated, skipping..."
    else
        @info "Running step 2: Extracting urls from $(length(sitemaps)) sitemap XMLs..."
        open(urls, "w") do io
            @showprogress for sitemap in sitemaps
                xdoc = readxml(sitemap)
                soup = root(xdoc)
                elems = elements(soup)
                prev_link = " "
                for e in elems
                    link = elements(e)[1].content
                    if is_hansard_link(link, sxml_house)
                        if !compare_links(link, prev_link)
                            prev_link = link
                            println(io, link)
                        end
                    end
                end
            end
        end
    end
    @debug "Found $(length(readlines(urls))) urls"
    return run(Val(Step3); paths=paths, sxml_house=sxml_house)
end

function run(::Val{Step3}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    urls_out = paths.interim
    existing_urls = joinpath(urls_out, "urls.txt")
    touch(existing_urls)
    urls_old = unique(readlines(existing_urls))
    date = string(today())
    new_urls = joinpath(urls_out, date * "_urls.txt")
    urls_new = unique(readlines(new_urls))
    missing_urls = joinpath(urls_out, "missing_urls.txt")
    urls_missing = setdiff(urls_new, urls_old)
    open(missing_urls, "w") do io
        write(io, join(urls_missing, "\n"))
    end
    open(existing_urls, "w") do io
        write(io, join([urls_missing..., urls_old...], "\n"))
    end
    @info "Step 3 finished, $(length(urls_missing)) new urls found, for a total of $(length(urls_missing) + length(urls_old)) urls..."
    return run(Val(Step4); paths=paths, sxml_house=sxml_house)
end

function run(::Val{Step4}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    htmls_out = paths.htmls
    urls = readlines(joinpath(paths.interim, "missing_urls.txt"))
    if length(urls) == 0
        @info "Step 4 already completed as no new urls are requested"
    else
        @info "Running step 4: Downloading $(length(urls) - length(readdir(htmls_out))) html files..."
        @showprogress for url in urls
            query = find_query_from_url(url)
            file = joinpath(htmls_out, query * ".html")
            download_file(url, file; filetype="text/html")
        end
    end
    return run(Val(Step5); paths=paths, sxml_house=sxml_house)
end

function run(::Val{Step5}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    xmls_out = paths.interim
    date = string(today())
    xmls = joinpath(xmls_out, date * "_xmls.csv")
    htmls = readdir(paths.htmls, join=true)
    if isfile(xmls) && length(readlines(xmls)) > 0
        @info "Step 5 already completed as $(xmls) exists and is populated, skipping..."
    else
        @info "Running step 5: Extracting xml and pdf links from $(length(htmls)) html files..."
        open(xmls, "w") do io
            println(io, join(["date", "xml_link", "pdf_link", "file"], "\t"))
            @showprogress for html in htmls
                text = read(html, String)
                doc = Gumbo.parsehtml(text)
                soup = doc.root
                date = find_date_subsoup(soup)
                pdf_link = xml_link = "N/A"
                try
                    xml_soup = eachmatch(sel"div#documentToc", soup)[1]
                    for subsoup in eachmatch(sel"a", xml_soup)
                        href = subsoup.attributes["href"]
                        if occursin(".xml", href)
                            xml_link = "https://parlinfo.aph.gov.au$href"
                        elseif occursin(".pdf", href)
                            pdf_link = "https://parlinfo.aph.gov.au$href"
                        end
                    end
                catch
                    nothing
                end
                println(io, join([date, xml_link, pdf_link, html], "\t"))
            end
        end
    end
    return run(Val(Step6); paths=paths, sxml_house=sxml_house)
end

function run(::Val{Step6}; paths::SXMLPaths, sxml_house::SXMLHouse)::Bool
    xmls_out = paths.xmls
    date = string(today())
    xmls_in = joinpath(paths.interim, date * "_xmls.csv")
    urls = readlines(xmls_in)[2:end]
    @info "Running step 6: Downloading up to $(length(urls)) xml files..."
    @showprogress for url in urls
        date, xml, _pdf, _f = split(url)
        if xml == "N/A"
            continue
        end
        day, month, year = split(date, "-")
        out = joinpath(xmls_out, year, "$(year)_$(month)_$(day).xml")
        mkpath(dirname(out))
        download_file(xml, out; filetype="text/xml")
    end
    return true
end

function run(::Val{Step7}; paths::SXMLPaths, should_compress::Bool)::Bool
    @info "Running step 7: Cleaning and compressing files..."
    if should_compress
        compress(paths.base, paths.base * ".tar.zst", clear=true)
    end
    return true
end

export main
function (@main)(_ARGS)
    return run(; get_args()...) ? 0 : 1
end

end
