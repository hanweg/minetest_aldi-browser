-- api.lua - HTTP API wrapper for ALDI US (Instacart GraphQL API)

-- Returns a function that takes http api and insecure environment, returns the api table
return function(http, insecure_env)

local api = {}

-- Get io.popen for cookie management
-- When secure.enable_security = false, io.popen is already a global.
-- When security is enabled, we need it from the insecure environment.
local io_popen = (insecure_env and insecure_env.io and insecure_env.io.popen)
                 or (io and io.popen)  -- fallback to global when security is disabled

if io_popen then
    minetest.log("action", "[aldi_browser] io.popen available - cookie support enabled")
else
    minetest.log("warning", "[aldi_browser] io.popen NOT available - cookie auth will fail")
end

-- GraphQL endpoint and storefront URL for session cookies
local GRAPHQL_URL = "https://www.aldi.us/graphql"
local STOREFRONT_URL = "https://www.aldi.us/store/aldi/storefront"

-- Persisted query hashes (from Instacart webpack bundles)
local HASHES = {
    AutoCompleteLocations = "a16f69a15e8b42f1f6d726ed3368fda623f1fca7c4f41139e032cf8d9f7da279",
    DefaultShop           = "607e5aea2e2f7b3d8bf89bb7f657ce5c13bc12f89f70a7f7e6b2f1c13ded18a8",
    ShopWithRis           = "c36a490a7070e0e81da09f331848e0e07d94ce1aeaf3c709df5fc71727ff769a",
    Search                = "539a60b5f92d59095b87f403f26a11187ad33e080c8a6575aeea9c5ad9501a7a",
    AisleNavCollections   = "72fbba6c55efc3a6ea8e609d0b7b21e7ee18b67f79ac3978b1f1c65665c5601d",
    GetRetailerLocationAddress = "b80a5ef08c6fe88df0b9a2e78a099dd6141345b213df0f9f517803674b6eee94",
}

-- Standard department slugs
api.DEPARTMENT_SLUGS = {
    "produce", "dairy", "meat-seafood", "bread", "deli", "frozen",
    "snacks", "beverages", "breakfast", "canned-goods",
    "condiments-sauces", "pasta", "household", "personal-care",
    "health-care", "baby", "pets",
}

-- Cached session cookie (shared across all players)
local session_cookie = nil
local session_cookie_time = 0
local SESSION_COOKIE_TTL = 300  -- refresh every 5 minutes

-- JSON encode a Lua table (simple implementation for GraphQL payloads)
local function json_encode(val)
    if val == nil then
        return "null"
    elseif type(val) == "boolean" then
        return val and "true" or "false"
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "string" then
        -- Escape special characters
        local escaped = val:gsub('\\', '\\\\')
                           :gsub('"', '\\"')
                           :gsub('\n', '\\n')
                           :gsub('\r', '\\r')
                           :gsub('\t', '\\t')
        return '"' .. escaped .. '"'
    elseif type(val) == "table" then
        -- Check if array or object
        local is_array = (#val > 0) or next(val) == nil
        if is_array and #val > 0 then
            local parts = {}
            for i, v in ipairs(val) do
                parts[i] = json_encode(v)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        elseif not is_array then
            local parts = {}
            for k, v in pairs(val) do
                parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        else
            return "[]"
        end
    end
    return "null"
end

-- Build a persisted query request body
local function build_graphql_body(operation_name, variables)
    return json_encode({
        operationName = operation_name,
        variables = variables,
        extensions = {
            persistedQuery = {
                version = 1,
                sha256Hash = HASHES[operation_name],
            }
        }
    })
end

-- Fetch session cookie using curl (requires insecure environment)
-- Minetest's http.fetch doesn't expose response headers, so we can't
-- extract the Set-Cookie header. We use curl via io.popen instead.
local function fetch_session_cookie_curl()
    if not io_popen then
        return nil
    end

    local cmd = 'curl -s -c - "' .. STOREFRONT_URL .. '" -o /dev/null 2>/dev/null'
    local handle = io_popen(cmd, "r")
    if not handle then
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    if not output then return nil end

    -- Parse Netscape cookie format for __Host-instacart_sid
    -- HttpOnly cookies are prefixed with #HttpOnly_ (NOT a comment), so
    -- we must not skip lines starting with #.
    for line in output:gmatch("[^\n]+") do
        -- Skip actual comment lines (start with "# " or are just "#")
        -- but NOT #HttpOnly_ lines
        if line:match("__Host%-instacart_sid") then
            -- Format: [#HttpOnly_]domain\tflags\tpath\tsecure\texpiry\tname\tvalue
            local value = line:match("__Host%-instacart_sid%s+(.+)$")
            if value then
                value = value:match("^%s*(.-)%s*$")
                minetest.log("action", "[aldi_browser] Session cookie obtained")
                return "__Host-instacart_sid=" .. value
            end
        end
    end

    minetest.log("warning", "[aldi_browser] curl ran but no session cookie found in output (" ..
                 #output .. " bytes)")

    return nil
end

-- Get a valid session cookie, refreshing if stale
local function ensure_session_cookie(callback)
    local now = os.time()
    if session_cookie and session_cookie ~= "" and (now - session_cookie_time) < SESSION_COOKIE_TTL then
        callback(session_cookie)
        return
    end

    -- Use curl to fetch cookie (synchronous but fast since we discard body)
    local cookie = fetch_session_cookie_curl()
    if cookie and cookie ~= "" then
        session_cookie = cookie
        session_cookie_time = now
        callback(cookie)
    else
        -- No insecure env or curl failed - try without cookie
        session_cookie = nil
        callback(nil, "Could not obtain session cookie. " ..
                 "Ensure 'aldi_browser' is in secure.trusted_mods in minetest.conf " ..
                 "and that curl is installed.")
    end
end

-- Make a GraphQL request
local function graphql_request(operation_name, variables, callback)
    if not http then
        callback(nil, "HTTP API not available")
        return
    end

    local body = build_graphql_body(operation_name, variables)

    ensure_session_cookie(function(cookie, cookie_err)
        if cookie_err then
            callback(nil, cookie_err)
            return
        end

        local extra_headers = {"Content-Type: application/json"}
        if cookie and cookie ~= "" then
            extra_headers[#extra_headers + 1] = "Cookie: " .. cookie
        end

        http.fetch({
            url = GRAPHQL_URL,
            timeout = 15,
            method = "POST",
            data = body,
            extra_headers = extra_headers,
        }, function(result)
            if not result.succeeded then
                callback(nil, "HTTP request failed (code: " .. (result.code or "unknown") .. ")")
                return
            end

            local data = minetest.parse_json(result.data)
            if not data then
                callback(nil, "Failed to parse GraphQL response")
                return
            end

            if data.errors and #data.errors > 0 then
                local msg = data.errors[1].message or "Unknown GraphQL error"
                callback(nil, "API error: " .. msg)
                return
            end

            callback(data.data, nil)
        end)
    end)
end

-- Find store by ZIP code
-- Flow: AutoCompleteLocations -> DefaultShop -> GetRetailerLocationAddress
-- callback(store_info, error_msg)
-- store_info = {shop_id, session_token, location_id, city_state, address, zip, latitude, longitude}
function api.find_store(zip, callback)
    -- Step 1: Geocode ZIP
    graphql_request("AutoCompleteLocations", {query = zip}, function(geo_data, err)
        if err then
            callback(nil, "Geocoding failed: " .. err)
            return
        end

        local locations = geo_data and geo_data.autocompleteLocations
                          and geo_data.autocompleteLocations.locations
        if not locations or #locations == 0 then
            callback(nil, "No location found for ZIP: " .. zip)
            return
        end

        local loc = locations[1]
        local lat = loc.coordinates and loc.coordinates.latitude
        local lng = loc.coordinates and loc.coordinates.longitude
        local city_state = loc.viewSection and loc.viewSection.lineTwoString or ""

        if not lat or not lng then
            callback(nil, "Could not determine coordinates for ZIP: " .. zip)
            return
        end

        -- Step 2: Get default shop
        graphql_request("DefaultShop", {
            retailerSlug = "aldi",
            postalCode = zip,
            coordinates = {latitude = lat, longitude = lng},
        }, function(shop_data, err2)
            if err2 then
                callback(nil, "Store lookup failed: " .. err2)
                return
            end

            local shop = shop_data and shop_data.defaultShop
            if not shop or not shop.id then
                callback(nil, "No ALDI store found near ZIP: " .. zip)
                return
            end

            local store_info = {
                shop_id = shop.id,
                session_token = shop.retailerInventorySessionToken or "",
                location_id = shop.retailerLocationId or "",
                city_state = city_state,
                address = nil,
                zip = zip,
                latitude = lat,
                longitude = lng,
            }

            -- Step 3: Get store address (optional, don't fail if it errors)
            if store_info.location_id ~= "" then
                graphql_request("GetRetailerLocationAddress", {
                    retailerLocationId = store_info.location_id,
                }, function(addr_data, err3)
                    if not err3 and addr_data and addr_data.retailerLocationAddress then
                        store_info.address = addr_data.retailerLocationAddress.streetAddress
                    end
                    callback(store_info, nil)
                end)
            else
                callback(store_info, nil)
            end
        end)
    end)
end

-- Refresh session token for an existing shop (when token expires)
-- callback(session_token, error_msg)
function api.refresh_session_token(shop_id, callback)
    graphql_request("ShopWithRis", {
        id = shop_id,
        postalCode = "00000",
        coordinates = {latitude = 0, longitude = 0},
    }, function(data, err)
        if err then
            callback(nil, "Token refresh failed: " .. err)
            return
        end

        local token = data and data.shop and data.shop.retailerInventorySessionToken
        if not token or token == "" then
            callback(nil, "Could not get session token for shop " .. shop_id)
            return
        end

        callback(token, nil)
    end)
end

-- Helper: ensure we have a valid session token, refreshing if needed
local function with_session_token(shop_id, session_token, callback)
    if session_token and session_token ~= "" then
        callback(session_token)
        return
    end
    api.refresh_session_token(shop_id, function(token, err)
        if err then
            callback(nil, err)
            return
        end
        callback(token)
    end)
end

-- Search products at a store
-- callback({products, total_count, offset, limit}, error_msg)
function api.search_products(shop_id, session_token, query, offset, limit, callback)
    limit = limit or 24
    offset = offset or 0
    if limit > 60 then limit = 60 end

    with_session_token(shop_id, session_token, function(token, token_err)
        if token_err then
            callback(nil, token_err)
            return
        end

        graphql_request("Search", {
            query = query or "",
            pageSize = limit,
            offset = offset,
            shopId = shop_id,
            zoneId = "1",
            postalCode = "00000",
            retailerInventorySessionToken = token,
        }, function(data, err)
            if err then
                callback(nil, err)
                return
            end

            local items_list = data and data.searchResults
                               and data.searchResults.primaryItemResultList
                               and data.searchResults.primaryItemResultList.items
            if not items_list then
                callback({products = {}, total_count = 0, offset = offset, limit = limit}, nil)
                return
            end

            local products = {}
            for i, item in ipairs(items_list) do
                local price_str = ""
                local unit_price = ""
                local was_price = nil
                local price_value = ""

                if item.price and item.price.viewSection and item.price.viewSection.itemCard then
                    local card = item.price.viewSection.itemCard
                    price_str = card.priceString or ""
                    unit_price = card.pricingUnitString or ""
                    was_price = card.fullPriceString
                end
                if item.price and item.price.viewSection then
                    price_value = item.price.viewSection.priceValueString or ""
                end

                local available = true
                local stock_level = ""
                if item.availability then
                    available = item.availability.available ~= false
                    stock_level = item.availability.stockLevel or ""
                end

                products[i] = {
                    name = item.name or "Unknown",
                    price = price_str,
                    unit_price = unit_price,
                    was_price = was_price,
                    price_value = price_value,
                    brand = item.brandName or "",
                    size = item.size or "",
                    available = available,
                    stock_level = stock_level,
                }
            end

            -- The GraphQL API doesn't return total_count directly in the same way.
            -- We use the items count to infer if there are more pages.
            local total_count = #products
            -- If we got a full page, there are likely more results
            if #products >= limit then
                total_count = offset + limit + 1  -- signal there's at least one more page
            else
                total_count = offset + #products
            end

            callback({
                products = products,
                total_count = total_count,
                offset = offset,
                limit = limit,
                session_token = token,  -- pass back in case it was refreshed
            }, nil)
        end)
    end)
end

-- Get departments/categories for a store
-- callback(categories, error_msg)
-- categories = {{slug, name, subcategories}, ...}
function api.get_categories(shop_id, session_token, callback)
    with_session_token(shop_id, session_token, function(token, token_err)
        if token_err then
            callback(nil, token_err)
            return
        end

        local categories = {}
        local pending = #api.DEPARTMENT_SLUGS
        local had_error = false

        for _, slug in ipairs(api.DEPARTMENT_SLUGS) do
            graphql_request("AisleNavCollections", {
                shopId = shop_id,
                retailerInventorySessionToken = token,
                slug = slug,
            }, function(data, err)
                pending = pending - 1

                if not had_error and not err and data and data.collection then
                    local col = data.collection
                    local subcats = {}
                    if col.childCollections then
                        for j, child in ipairs(col.childCollections) do
                            subcats[j] = {
                                name = child.name or "",
                                slug = child.slug or "",
                            }
                        end
                    end
                    categories[#categories + 1] = {
                        slug = slug,
                        name = col.name or slug,
                        id = col.id or "",
                        subcategories = subcats,
                    }
                end

                if pending == 0 then
                    if #categories == 0 then
                        callback(nil, "No departments found")
                    else
                        -- Sort by original slug order
                        local slug_order = {}
                        for idx, s in ipairs(api.DEPARTMENT_SLUGS) do
                            slug_order[s] = idx
                        end
                        table.sort(categories, function(a, b)
                            return (slug_order[a.slug] or 999) < (slug_order[b.slug] or 999)
                        end)
                        callback(categories, nil, token)
                    end
                end
            end)
        end
    end)
end

-- Search products by category slug
-- Uses the category name as the search term
-- callback({products, total_count, offset, limit, category_name}, error_msg)
function api.search_by_category(shop_id, session_token, category_slug, offset, limit, callback)
    limit = limit or 24
    offset = offset or 0
    if limit > 60 then limit = 60 end

    with_session_token(shop_id, session_token, function(token, token_err)
        if token_err then
            callback(nil, token_err)
            return
        end

        -- First get the category display name
        graphql_request("AisleNavCollections", {
            shopId = shop_id,
            retailerInventorySessionToken = token,
            slug = category_slug,
        }, function(nav_data, nav_err)
            -- Use category name as search term, fall back to slug with hyphens replaced
            local search_term = category_slug:gsub("%-", " ")
            local category_name = search_term
            if not nav_err and nav_data and nav_data.collection then
                category_name = nav_data.collection.name or category_name
                search_term = category_name
            end

            -- Search with category name as query
            graphql_request("Search", {
                query = search_term,
                pageSize = limit,
                offset = offset,
                shopId = shop_id,
                zoneId = "1",
                postalCode = "00000",
                retailerInventorySessionToken = token,
            }, function(data, err)
                if err then
                    callback(nil, err)
                    return
                end

                local items_list = data and data.searchResults
                                   and data.searchResults.primaryItemResultList
                                   and data.searchResults.primaryItemResultList.items
                if not items_list then
                    callback({
                        products = {}, total_count = 0, offset = offset,
                        limit = limit, category_name = category_name,
                        session_token = token,
                    }, nil)
                    return
                end

                local products = {}
                for i, item in ipairs(items_list) do
                    local price_str = ""
                    local unit_price = ""
                    local was_price = nil

                    if item.price and item.price.viewSection and item.price.viewSection.itemCard then
                        local card = item.price.viewSection.itemCard
                        price_str = card.priceString or ""
                        unit_price = card.pricingUnitString or ""
                        was_price = card.fullPriceString
                    end

                    local available = true
                    if item.availability then
                        available = item.availability.available ~= false
                    end

                    products[i] = {
                        name = item.name or "Unknown",
                        price = price_str,
                        unit_price = unit_price,
                        was_price = was_price,
                        brand = item.brandName or "",
                        size = item.size or "",
                        available = available,
                    }
                end

                local total_count = #products
                if #products >= limit then
                    total_count = offset + limit + 1
                else
                    total_count = offset + #products
                end

                callback({
                    products = products,
                    total_count = total_count,
                    offset = offset,
                    limit = limit,
                    category_name = category_name,
                    session_token = token,
                }, nil)
            end)
        end)
    end)
end

return api
end
