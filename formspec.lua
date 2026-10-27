-- formspec.lua - Formspec building functions for ALDI browser

local formspec = {}

-- Escape text for formspec display
local function fs_escape(text)
    if not text then return "" end
    text = tostring(text)
    -- Escape backslashes first, then other special characters
    text = text:gsub("\\", "\\\\")
    text = text:gsub("%[", "\\[")
    text = text:gsub("%]", "\\]")
    text = text:gsub(";", "\\;")
    text = text:gsub(",", "\\,")
    return text
end

-- Build the main menu formspec
function formspec.main_menu(ctx)
    local store_info = "No store selected"
    if ctx.shop_id then
        store_info = "ALDI"
        if ctx.store_city and ctx.store_city ~= "" then
            store_info = store_info .. " - " .. ctx.store_city
        end
        if ctx.store_address then
            store_info = store_info .. " (" .. ctx.store_address .. ")"
        end
    end

    local fs = "formspec_version[4]" ..
               "size[10,7]" ..
               "label[0.5,0.5;ALDI Price Browser]" ..
               "label[0.5,1.2;Store: " .. fs_escape(store_info) .. "]" ..
               "field[0.5,2;6,0.8;zip;ZIP Code;" .. fs_escape(ctx.zip or "") .. "]" ..
               "button[6.7,2;2.8,0.8;find_store;Find Store]"

    if ctx.loading then
        fs = fs .. "label[3.5,3.5;Finding store...]"
    else
        fs = fs .. "button[0.5,3.5;4,1;search_products;Search Products]" ..
                   "button[5.5,3.5;4,1;browse_categories;Browse Categories]"
    end

    fs = fs .. "button[3.5,5.5;3,1;close;Close]"

    if ctx.error_msg then
        fs = fs .. "label[0.5,6.2;" .. fs_escape(ctx.error_msg) .. "]"
    end

    return fs
end

-- Build the product search formspec
function formspec.product_search(ctx, results)
    local store_info = "ALDI"
    if ctx.store_city and ctx.store_city ~= "" then
        store_info = store_info .. " - " .. ctx.store_city
    end

    local fs = "formspec_version[4]" ..
               "size[14,11]" ..
               "label[0.5,0.4;ALDI Product Search - " .. fs_escape(store_info) .. "]" ..
               "field[0.5,1.1;9,0.8;search_query;;" .. fs_escape(ctx.search_query or "") .. "]" ..
               "field_close_on_enter[search_query;false]" ..
               "button[9.7,1.1;3.8,0.8;do_search;Search]"

    if ctx.loading then
        fs = fs .. "label[5,5;Loading...]"
    elseif results and results.products then
        -- Build product list
        local product_items = {}
        for i, product in ipairs(results.products) do
            local item = product.name
            if product.brand and product.brand ~= "" then
                item = item .. " (" .. product.brand .. ")"
            end
            if product.price and product.price ~= "" then
                item = item .. " - " .. product.price
            end
            if product.unit_price and product.unit_price ~= "" then
                item = item .. " [" .. product.unit_price .. "]"
            end
            if product.was_price then
                item = item .. " (Was: " .. product.was_price .. ")"
            end
            if not product.available then
                item = item .. " [OUT OF STOCK]"
            end
            product_items[i] = fs_escape(item)
        end

        if #product_items > 0 then
            local selected = ctx.selected_product_index or 1
            fs = fs .. "textlist[0.5,2.2;13,6.8;product_list;" .. table.concat(product_items, ",") .. ";" .. selected .. "]"

            -- Pagination info
            local page = math.floor((results.offset or 0) / (results.limit or 24)) + 1
            local total_pages = math.ceil((results.total_count or 0) / (results.limit or 24))
            if total_pages < 1 then total_pages = 1 end

            fs = fs .. "label[5.5,9.3;Page " .. page .. " of " .. total_pages .. "]"
            fs = fs .. "button[0.5,9.1;2.5,0.8;prev_page;< Prev]"
            fs = fs .. "button[11,9.1;2.5,0.8;next_page;Next >]"
        else
            fs = fs .. "label[5,5;No products found]"
        end
    else
        fs = fs .. "label[5,5;Enter a search term and click Search]"
    end

    fs = fs .. "button[0.5,10.2;3,0.8;back;Main Menu]"
    fs = fs .. "button[10.5,10.2;3,0.8;view_detail;View Details]"

    if ctx.error_msg then
        fs = fs .. "label[0.5,9.8;" .. fs_escape(ctx.error_msg) .. "]"
    end

    return fs
end

-- Build the category browser formspec
function formspec.category_browser(ctx, categories, results)
    local store_info = "ALDI"
    if ctx.store_city and ctx.store_city ~= "" then
        store_info = store_info .. " - " .. ctx.store_city
    end

    local fs = "formspec_version[4]" ..
               "size[14,11]" ..
               "label[0.5,0.4;ALDI Categories - " .. fs_escape(store_info) .. "]"

    if categories and #categories > 0 then
        -- Build category dropdown using display names
        local cat_items = {}
        local selected_idx = 1
        for i, cat in ipairs(categories) do
            cat_items[i] = fs_escape(cat.name)
            if ctx.selected_category == cat.slug then
                selected_idx = i
            end
        end

        fs = fs .. "dropdown[0.5,1;6,0.8;category_select;" .. table.concat(cat_items, ",") .. ";" .. selected_idx .. ";true]"
        fs = fs .. "button[6.7,1;3,0.8;load_category;Load Category]"
    else
        fs = fs .. "label[0.5,1.3;Loading categories...]"
    end

    if ctx.loading then
        fs = fs .. "label[5,5;Loading...]"
    elseif results and results.products then
        -- Show category name
        if results.category_name then
            fs = fs .. "label[0.5,2;Category: " .. fs_escape(results.category_name) .. "]"
        end

        -- Build product list
        local product_items = {}
        for i, product in ipairs(results.products) do
            local item = product.name
            if product.brand and product.brand ~= "" then
                item = item .. " (" .. product.brand .. ")"
            end
            if product.price and product.price ~= "" then
                item = item .. " - " .. product.price
            end
            if product.unit_price and product.unit_price ~= "" then
                item = item .. " [" .. product.unit_price .. "]"
            end
            if product.was_price then
                item = item .. " (Was: " .. product.was_price .. ")"
            end
            if not product.available then
                item = item .. " [OUT OF STOCK]"
            end
            product_items[i] = fs_escape(item)
        end

        if #product_items > 0 then
            local selected = ctx.selected_product_index or 1
            fs = fs .. "textlist[0.5,2.5;13,6.3;product_list;" .. table.concat(product_items, ",") .. ";" .. selected .. "]"

            -- Pagination info
            local page = math.floor((results.offset or 0) / (results.limit or 24)) + 1
            local total_pages = math.ceil((results.total_count or 0) / (results.limit or 24))
            if total_pages < 1 then total_pages = 1 end

            fs = fs .. "label[5.5,9.1;Page " .. page .. " of " .. total_pages .. "]"
            fs = fs .. "button[0.5,8.9;2.5,0.8;prev_page;< Prev]"
            fs = fs .. "button[11,8.9;2.5,0.8;next_page;Next >]"
        else
            fs = fs .. "label[5,5;No products in this category]"
        end
    elseif categories and #categories > 0 then
        fs = fs .. "label[5,5;Select a category and click Load]"
    end

    fs = fs .. "button[0.5,10.2;3,0.8;back;Main Menu]"
    fs = fs .. "button[10.5,10.2;3,0.8;view_detail;View Details]"

    if ctx.error_msg then
        fs = fs .. "label[0.5,9.6;" .. fs_escape(ctx.error_msg) .. "]"
    end

    return fs
end

-- Build product detail formspec
function formspec.product_detail(ctx, product)
    local fs = "formspec_version[4]" ..
               "size[10,8]" ..
               "label[0.5,0.5;Product Details]"

    if product then
        local y = 1.3

        fs = fs .. "label[0.5," .. y .. ";Name: " .. fs_escape(product.name) .. "]"
        y = y + 0.7

        if product.brand and product.brand ~= "" then
            fs = fs .. "label[0.5," .. y .. ";Brand: " .. fs_escape(product.brand) .. "]"
            y = y + 0.7
        end

        fs = fs .. "label[0.5," .. y .. ";Price: " .. fs_escape(product.price or "N/A") .. "]"
        y = y + 0.7

        if product.unit_price and product.unit_price ~= "" then
            fs = fs .. "label[0.5," .. y .. ";Unit Price: " .. fs_escape(product.unit_price) .. "]"
            y = y + 0.7
        end

        if product.was_price then
            fs = fs .. "label[0.5," .. y .. ";Was: " .. fs_escape(product.was_price) .. " (ON SALE!)]"
            y = y + 0.7
        end

        if product.size and product.size ~= "" then
            fs = fs .. "label[0.5," .. y .. ";Size: " .. fs_escape(product.size) .. "]"
            y = y + 0.7
        end

        if product.available == false then
            fs = fs .. "label[0.5," .. y .. ";Availability: OUT OF STOCK]"
        else
            fs = fs .. "label[0.5," .. y .. ";Availability: In Stock]"
        end
    else
        fs = fs .. "label[3,3;No product selected]"
    end

    fs = fs .. "button[3.5,7;3,0.8;back;Back]"

    return fs
end

-- Build HTTP not available error formspec
function formspec.http_error()
    return "formspec_version[4]" ..
           "size[12,7]" ..
           "label[0.5,0.5;ALDI Browser - Configuration Required]" ..
           "label[0.5,1.5;This mod requires HTTP access and cookie support.]" ..
           "label[0.5,2.2;Add these lines to your minetest.conf:]" ..
           "label[0.5,3.2;secure.http_mods = aldi_browser]" ..
           "label[0.5,3.9;secure.trusted_mods = aldi_browser]" ..
           "label[0.5,4.9;Then restart Minetest. curl must also be installed.]" ..
           "button[4.5,6;3,0.8;close;Close]"
end

return formspec
