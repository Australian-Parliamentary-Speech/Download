using HTTP
using Gumbo
using Cascadia
using Downloads
using CSV
using DataFrames
using EzXML
using Dates
using ProgressMeter
using Logging
using ArgParse
include("utils.jl")


function get_args()
    s = ArgParseSettings()
    @add_arg_table s begin
        "which_house"
            required = true
    end
    return parse_args(s)
end

function main()
    args = get_args()
    which_house = args["which_house"]
    main(Symbol(which_house))
end
    

function dir_name(which_house)
    today_ = today()
    return Dict(1 => "sitemap_xmls_step1_$(which_house)",4 => "sitemap_htmls_step4_$(today_)$(which_house)", 6 => "sitemap_xmls_$(which_house)", "inter" => "sitemap_inter_csvs_$(which_house)", "log" => "sitemap_logfiles_$(which_house)")
end


#todo: what is going on with the compare and update. and what is going on with logging
#this is the function you run
function main(which_house)
    today_ = today()
    name_dict = dir_name(which_house)
    inter_csv_path = name_dict["inter"]
    create_dir(inter_csv_path)

    exist_today = filter(x -> occursin("$today_", x), readdir("$inter_csv_path/"))
    if length(exist_today) != 0
        @error "today's file already exist, running risk overwriting. pleasde delete all directories first"
    else
        log_dir = name_dict["log"]
        create_dir(log_dir) 
        logio = open("$(log_dir)/log_$today_.txt","w+")
        logger = SimpleLogger(logio)
        with_logger(logger) do
            sitemap_run(which_house)
        end
        flush(logio)
        close(logio)
    end
end

#step1: extract all xml links from the first url
#step2: extract all current up-to-date html links from all xml links 
#step3: compare the current html links with the existing html links (if exists) and create a file containing all the missing htmls
#step4: download the missing html files with query as their names
#step5: extract the missing xml links into a new csv
#step6: download those xmls into their respective folders.
#step7: add the xml links into the existing file if exists.
function sitemap_run(which_house)
    today_ = today()
    name_dict = dir_name(which_house)
    inter_csv_path = name_dict["inter"]
    dir_step1 = name_dict[1]
    dir_step4 = name_dict[4]
    dir_step6 = name_dict[6]

    previous_exist = false
    url = "https://parlinfo.aph.gov.au/sitemap/sitemapindex.xml"
    create_dir(inter_csv_path)
    step1(url,dir_step1)

    step2_html_fn = "$(inter_csv_path)/sitemap_html_step2_$(today_).csv"
    step2_exist_fn = filter(x -> occursin("sitemap_html_step2", x), readdir("$inter_csv_path/"))
    n_total = step2(dir_step1,step2_html_fn,which_house)
    @info n_total
    step2_missing_fn = "$(inter_csv_path)/sitemap_html_step2_missing.csv"
    step2_final_fn = if length(step2_exist_fn) != 0
        step3("$(inter_csv_path)/$(step2_exist_fn[1])",step2_html_fn,step2_missing_fn)
        previous_exist = true
        step2_missing_fn
    else
        step2_html_fn
    end

    create_dir(dir_step4)
    step4(step2_final_fn,dir_step4)

    step5_xml_fn = "$(inter_csv_path)/sitemap_xml_step5_$(today_).csv"
    step5(step5_xml_fn,dir_step4)

    create_dir(dir_step6)
    step6(step5_xml_fn,dir_step6)
   
    if previous_exist 
        previous_html_fn = "$(inter_csv_path)/$(step2_exist_fn[1])"
        extra_html_fn = step2_missing_fn
        csv_concatenate(previous_html_fn,step2_missing_fn,step2_html_fn)
        previous_xml_fn = filter(x -> occursin("sitemap_xml_step5", x), readdir("$inter_csv_path/"))[1]
        extra_xml_fn = step5_xml_fn
        csv_concatenate("$(inter_csv_path)/$(previous_xml_fn)",extra_xml_fn,extra_xml_fn)
        rm(previous_html_fn)
        rm("$(inter_csv_path)/$(previous_xml_fn)")
    end
end

function step6(step5_xml_fn,dir_step6)
    download_xml_from_file(step5_xml_fn,dir_step6,"-","\t")
end

function step5(step5_xml_fn,dir_step4)
    print("Step 5 has started, it extracts all the xml and pdf links from the htmls...")
    filelist = readdir("$(dir_step4)/")
    open(step5_xml_fn, "w") do io
        println(io,join(["date","xml_link","pdf_link","file"],"\t"))
        @showprogress for file in filelist
            text = read("$(dir_step4)/$file", String)
            doc = Gumbo.parsehtml(text)
            soup = doc.root
            date = find_date_subsoup(soup)
            pdf_link, xml_link = try
            xml_soup = eachmatch(sel"div#documentToc",soup)[1]
            pdf,xml = eachmatch(sel"a",xml_soup)[1].attributes["href"],eachmatch(sel"a",xml_soup)[2].attributes["href"]

            pdf_link =  "https://parlinfo.aph.gov.au/$pdf"
            xml_link = "https://parlinfo.aph.gov.au/$xml"
            (pdf_link,xml_link)
            catch
                pdf_link = xml_link = "N/A"
                (pdf_link,xml_link)
            end
            println(io, join([date, xml_link, pdf_link,file], "\t"))
        end 
    end
end


function find_date_subsoup(soup)
    date = try
        subsoup = eachmatch(sel"div.twoBoxForm",soup)[2]
        div = eachmatch(sel"div.metaPadding",subsoup)[1]
        date_soup = eachmatch(sel"p.mdItem",div)[1]
        date = date_soup.children[1].text
    catch
        date = "N/A"
    end
    return date
end


function step4(step2_final_fn,dir_step4)
    print("Step 4 has started, in this step we download the html files which include the xml links...")
    function find_query_from_url(url)
        pattern = r"query=([^;]+);"
        m = match(pattern, url)
        return m.captures[1]
    end
    html_list = readlines(step2_final_fn)
    for html in html_list[2:end]
        continue_ = true
        repeat = 0
        while continue_
            try
                @show html
                response = get_response(html)
                html_content = String(response.body)
                query = find_query_from_url(html)
                filename = "$(dir_step4)/$(query).html"
                open(filename, "w") do file
                    write(file,html_content)
                end
                continue_ = false
            catch e
                print("Waiting for Internet to respond...") 
                println("An error occurred: $e")
                sleep(50)
                continue_ = true
            end 
            repeat += 1
            if repeat > 5
                continue_ = false
                @info "step4 failed html links: $(html)"
            end
        end
    end   
end

function step3(step2_exist_fn,step2_html_fn,step2_missing_fn)
    print("The third step has been activated, generating the missing links...")
    html_exist = readlines(step2_exist_fn)
    html_new = readlines(step2_html_fn)
    #performance check
#    html_missing = html_new[html_new .∉ Ref(html_exist)]
    html_missing = setdiff(html_new,html_exist)
    open(step2_missing_fn,"w") do io
        println(io,"html")

        @info "The missing number of html links is $(length(html_missing))"
        for html in html_missing
            println(io,html)
        end
    end
end

function find_1997()
    function if_link_sgml(link)
        return occursin("sgml",link)
    end
    today_ = today()
    dir_step1 = "sitemap_xmls_step1"
    filelist = readdir("$dir_step1/")
    open("1995.csv","w") do io
        for xml_file in filelist
            xdoc = readxml("$dir_step1/$xml_file")
            soup = root(xdoc)
            eles = elements(soup)
            for ele in eles
                for l in elements(ele)
                    link = l.content
                    if if_link_sgml(link)
                        @show link
                        println(io,link)
                    end
                end
            end
        end
    end
end

function step2(dir_step1,step2_html_fn,which_house)
    function if_link_hansard(link,which_house)
        if which_house == :house
            return occursin("hansardr80",link) || occursin("hansardr",link)
        elseif which_house == :senate
            return occursin("hansards80",link) || occursin("hansards",link)
        end
    end

    function compare_links(url1::String, url2::String)::Bool
        pattern = r"%2F\d+%22"    
        cleaned_url1 = replace(url1, pattern => "")
        cleaned_url2 = replace(url2, pattern => "")
        return cleaned_url1 == cleaned_url2
    end
    print("The second step has started, it is gathering up all the html links from the sitemap...")

    filelist = readdir("$dir_step1/")
    n_total = 0
    open(step2_html_fn,"w") do io
        println(io,"html")
        @showprogress for xml_file in filelist
            xdoc = readxml("$dir_step1/$xml_file")
            soup = root(xdoc)
            eles = elements(soup)
            prev_link = " "
            for ele in eles
                link = elements(ele)[1].content
                if if_link_hansard(link,which_house)
                    n_total += 1
                    if !(compare_links(link,prev_link))
                        prev_link = link
                        println(io,link)
                    end
                end
            end
        end
    end
    return n_total
end

function step1(url,dir_step1)
    print("The first step started, it is downloading the second layer of the XML files...")
    create_dir("$(dir_step1)/")
    download_xml(url,"xml_for_step1.xml")
    xdoc = readxml("xml_for_step1.xml")
    soup = root(xdoc)
    eles = elements(soup)
    first_sets = []
    fn = 1
    @showprogress for ele in eles
        link = elements(ele)[1].content
        download_xml(link,"$dir_step1/$fn.xml")
        fn+=1
    end
end


if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

