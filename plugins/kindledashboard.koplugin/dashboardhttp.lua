-- Native KOReader HTTPS transport. Blocking requests run inside the fetch subprocess.
local HTTP = {}

function HTTP.encode(value)
    return (tostring(value):gsub("([^%w%-._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

local function matchesHost(name, host)
    if type(name) ~= "string" then return false end
    name = name:lower()
    if name == host then return true end
    -- A wildcard covers exactly one DNS label, never an entire suffix.
    local suffix = name:match("^%*%.([%w.-]+)$")
    return suffix ~= nil and suffix:find(".", 1, true) ~= nil
        and host:match("^[^.]+%.(.+)$") == suffix
end

function HTTP.requestText(url, options)
    options = options or {}
    local host, port = tostring(url):match("^https://([%w.-]+):(%d+)[/?]")
    if not host then host = tostring(url):match("^https://([%w.-]+)[/?]") end
    if not host then host, port = tostring(url):match("^https://([%w.-]+):(%d+)$") end
    if not host then host = tostring(url):match("^https://([%w.-]+)$") end
    if not host or host:find("..", 1, true) or host:sub(1, 1) == "."
        or host:sub(-1) == "." or (port and (tonumber(port) < 1 or tonumber(port) > 65535)) then
        return nil, "A valid HTTPS URL is required"
    end
    host = host:lower()
    local http = require("socket.http")
    local https = require("ssl.https")
    local socketutil = require("socketutil")
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    local chunks, bytes = {}, 0
    socketutil:set_timeout(options.block_timeout or 4, options.total_timeout or 8)
    local ok, success, code = pcall(function()
        local sink = socketutil.table_sink(chunks)
        local request = {
            url = url, method = "GET", redirect = false,
            cafile = "data/ca-bundle.crt", verify = "peer", protocol = options.protocol or "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; KindleDashboard/1.0; KOReader)",
                ["Accept"] = "application/json", ["Accept-Encoding"] = "identity",
                ["Referer"] = options.referer,
            },
            sink = function(chunk, err)
                if chunk then
                    bytes = bytes + #chunk
                    if bytes > (options.max_bytes or 1024 * 1024) then
                        return nil, "JSON response too large"
                    end
                end
                return sink(chunk, err)
            end,
        }
        local create_tls = https.tcp(request)
        request.create = function()
            local connection = create_tls()
            local connect = connection.connect
            connection.connect = function(self, actual_host, actual_port)
                if actual_host:lower() ~= host then return nil, "Unexpected TLS host" end
                local connected, err = connect(self, actual_host, actual_port)
                if not connected then return nil, err end
                local certificate = self:getpeercertificate()
                local extensions = certificate and certificate:extensions() or {}
                local san = extensions["2.5.29.17"]
                local names = type(san) == "table" and san.dNSName or {}
                for _, name in ipairs(type(names) == "table" and names or {}) do
                    if matchesHost(name, host) then return 1 end
                end
                self:close()
                return nil, "TLS hostname verification failed"
            end
            return connection
        end
        return http.request(request)
    end)
    socketutil:set_timeout(old_block, old_total)
    if not ok then return nil, tostring(success) end
    if not success then return nil, tostring(code or "HTTPS request failed") end
    if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(chunks)
end

function HTTP.requestJSON(url, options)
    local body, err = HTTP.requestText(url, options)
    if not body then return nil, err end
    local decoded, payload = pcall(require("json").decode, body)
    if not decoded or type(payload) ~= "table" then return nil, "Invalid JSON response" end
    return payload
end

return HTTP
