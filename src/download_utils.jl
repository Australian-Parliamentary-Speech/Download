using HTTP

function get_response(url)
    headers = [
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        "Accept-Language" => "en-AU,en-US;q=0.9,en;q=0.8",
        "Accept-Encoding" => "gzip, deflate, br",
        "Connection" => "keep-alive",
        "Upgrade-Insecure-Requests" => "1",
        "Sec-Fetch-Dest" => "document",
        "Sec-Fetch-Mode" => "navigate",
        "Sec-Fetch-Site" => "none",
        "Sec-Fetch-User" => "?1",
        "Cache-Control" => "max-age=0"
    ]

    response = HTTP.get(url, headers; readtimeout=30, connect_timeout=10)

    # Add a delay to avoid triggering rate limits
    sleep(rand(1.0:0.1:3.0))

    return response
end

