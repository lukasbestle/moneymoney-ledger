-- MoneyMoney extension for transaction export in ledger format
-- for text-based double-entry accounting
-- https://github.com/lukasbestle/moneymoney-ledger
--
---------------------------------------------------------
--
-- MIT License
--
-- Copyright (c) 2023 Lukas Bestle
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

Exporter({
    version = 1.10,
    format = "Ledger",
    fileExtension = "journal",
    reverseOrder = true, -- export transactions in chronological order
    description = MM.language == "de" and "Export von Umsätzen als ledger .journal-Datei"
        or "Export transactions as ledger .journal file",
    options = {
        {
            label = MM.language == "de" and "Umsätze müssen kategorisiert sein"
                or "Transactions must have a category",
            name = "needsCategory",
            default = true,
        },
        {
            label = MM.language == "de" and "Umsätze müssen als erledigt markiert sein"
                or "Transactions must be checked",
            name = "needsCheckmark",
            default = true,
        },
    },
})

-- define local variables and functions
---@type string[]
local transactionErrors
local extractRegex, formatTags, localizeText, parseCategory, parseTags, processTransaction, trim

-- define types
---@class LedgerTransaction
---@field header string Part with the shared information in a group
---@field posting string Part with the counter transaction
---@field error string? Optional transaction error

-----------------------------------------------------------

---Writes the first line(s) of the export file;
---called only once per export on the first account
---
---@param account Account Account from which transactions are being exported
---@param startDate timestamp Booking date of the oldest transaction
---@param endDate timestamp Booking date of the newest transaction
---@param transactionCount integer Number of transactions to be exported
---@param options table<string, boolean> Export options from the `Exporter` constructor
---@return string? error Optional error message that aborts the export
function WriteHeader(account, startDate, endDate, transactionCount, options)
    -- find the decimal mark for the current locale (`.` or `,`)
    -- by extracting it from a string formatted as `0.00` or `0,00`
    local decimalMark = MM.localizeAmount(0):sub(2, 2)

    assert(io.write("; Export: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. "decimal-mark " .. decimalMark .. "\n"))

    -- reset the error list from previous exports
    transactionErrors = {}
end

---Writes a consecutive list of transactions of the same account;
---called multiple times if transactions from multiple accounts are exported
---
---@param account Account Account from which transactions are being exported
---@param transactions Transaction[] List of transactions of a booking date
---@param options table<string, boolean> Export options from the `Exporter` constructor
---@return string? error Optional error message that aborts the export
function WriteTransactions(account, transactions, options)
    local financialAccount = account.attributes.LedgerAccount or ("Assets:" .. account.name)

    -- process all transactions into groups that share their header and error
    local transactionGroups, transactionGroupOrder = {}, {}
    for _, transaction in ipairs(transactions) do
        local ledgerTransaction, hash = processTransaction(transaction, options)

        -- ensure that the group has its own table
        if not transactionGroups[hash] then
            transactionGroups[hash] = {}

            -- keep an ordered list to be able to print
            -- the groups in the correct order later
            table.insert(transactionGroupOrder, hash)
        end

        table.insert(transactionGroups[hash], ledgerTransaction)

        -- generate a user-facing error message for each individual errorneous
        -- transaction (even if grouped to display different amounts)
        if ledgerTransaction.error then
            local transactionError = string.format(
                "%s:\n%s · %s (%s)",
                ledgerTransaction.error,
                MM.localizeDate(transaction.bookingDate),
                transaction.name,
                MM.localizeAmount(transaction.amount, transaction.currency)
            )

            -- collect the message in the global list for aggregate output
            table.insert(transactionErrors, transactionError)
        end
    end

    -- now print all transaction groups in the order they were created
    for _, hash in ipairs(transactionGroupOrder) do
        local group = transactionGroups[hash]

        -- we can get the header and error from the first
        -- transaction as they all share those properties
        local firstTransaction = group[1]

        -- assemble the transaction string from the shared header,
        -- the individual postings and the shared financial account
        local output = firstTransaction.header
        for _, ledgerTransaction in ipairs(group) do
            output = output .. "\n  " .. ledgerTransaction.posting
        end
        output = output .. "\n  " .. financialAccount:gsub("%s+", " ")

        if firstTransaction.error then
            -- prepend the error to the output as comment;
            -- convert the output to line comments to comment out the invalid transaction
            output = ("; Error: " .. firstTransaction.error .. "\n" .. output):gsub("\n", "\n; ")
        end

        -- print the transaction to the export file;
        -- leading newline so that there is an empty line before the
        -- first transaction but also in between each transaction
        assert(io.write("\n" .. output .. "\n"))
    end
end

---Writes the last line(s) of the export file;
---called only once per export on the first account
---
---@param account Account Account from which transactions are being exported
---@param options table<string, boolean> Export options from the `Exporter` constructor
---@return string? error Optional error message that aborts the export
function WriteTail(account, options)
    -- return error message if the list is non-empty
    if next(transactionErrors) then
        local message = localizeText(
            "Incomplete export because of transaction errors:",
            "Unvollständiger Export wegen Fehlern bei Umsätzen:"
        )

        return (message .. "\n\n" .. table.concat(transactionErrors, "\n\n"))
    end
end

-----------------------------------------------------------

---Extracts a value from the string by regular expression;
---if the regex doesn't match, returns the string unaltered
---
---@param str string
---@param regex string
---@param multiple? boolean If `true`, all matches are returned as a list
---@return string str Remaining string
---@return string[] results Single or multiple matches
---@overload fun(str: string, regex: string): string, string
function extractRegex(str, regex, multiple)
    local results = {}

    for match in str:gmatch(regex) do
        -- collect the matched value
        table.insert(results, match)

        -- find the position of the match in the string
        -- while treating the match string as plain text
        local i, j = str:find(match, nil, true)

        -- remove the match from the string and ensure that there
        -- is exactly one space where the match was to fill the gap
        str = trim(trim(str:sub(0, i - 1)) .. " " .. trim(str:sub(j + 1)))
    end

    if multiple == true then
        return str, results
    end

    return str, table.remove(results)
end

---Converts a list of tags into a ledger output string
---
---@param tags table<string | integer, string> List of preformatted tags or key-value table
---@param separator string String to print in between tags
---@param start? string String to print at the start of the returned string if tags are being printed
---@return string
function formatTags(tags, separator, start)
    local tagStrings = {}

    for key, value in pairs(tags) do
        if type(key) == "number" then
            -- print tag as is without using the key
            value = "; " .. value
        elseif value and value ~= "" then
            value = "; " .. key .. ": " .. value
        else
            value = "; " .. key .. ":"
        end

        table.insert(tagStrings, value)
    end

    -- check if the list is non-empty
    if next(tagStrings) then
        return (start or "") .. table.concat(tagStrings, separator)
    else
        return ""
    end
end

---Returns the string in the current UI language
---
---@param en string English text
---@param de string German text
function localizeText(en, de)
    return MM.language == "de" and de or en
end

---Extracts tags from a hierarchical category name and
---converts the labels or optionally the overridden
---`[name]` into an account name hierarchy
---
---@param name string
---@return string[] hierarchy List of the account name levels
---@return table<string, string> tags Extracted tags
function parseCategory(name)
    -- extract the tags first, which will ensure that
    -- tags defined in lower levels override higher ones
    local tags
    name, tags = parseTags(name)

    -- collect each level that will be used
    local hierarchy = {}

    for levelName in name:gmatch("([^\\]+)") do
        -- extract the `[name]` tag
        local nameOverride
        levelName, nameOverride = extractRegex(levelName, "%[.-%]")

        if nameOverride then
            -- there was a `[name]` tag

            if nameOverride ~= "[]" then
                -- it is non-empty, so replace the hierarchy with it
                hierarchy = { nameOverride:match("%[(.-)%]") }
            end

        -- otherwise this hierarchy level will be skipped
        else
            -- there was no `[name]` tag, use the plain name
            table.insert(hierarchy, trim(levelName))
        end
    end

    return hierarchy, tags
end

---Extracts the `{tax}` and `#custom` tags from a string
---
---@param str string
---@param transaction? boolean If `true`, the `<code>` and `[date]` tags are extracted as well
---@return string str Remaining string
---@return table<string, string> tags Extracted tags
function parseTags(str, transaction)
    local tags = {}
    local result

    -- transaction-specific tags
    if transaction == true then
        -- `<code>` tag
        str, result = extractRegex(str, "<.->")
        if result then
            tags.code = result:match("<(.-)>")
        end

        -- `[date]` tag
        str, result = extractRegex(str, "%[.-%]")
        if result then
            tags.date = result
        end
    end

    -- `{tax}` tag
    str, result = extractRegex(str, "{.-}")
    if result then
        tags.tax = result:match("{(.-)}")
    end

    -- `#custom` tags (parsed last to allow using the `#` inside other tags)
    str, result = extractRegex(str, "#[^%s]+", true)
    for _, tag in ipairs(result) do
        local name, value = tag:match("^#([^:]+):?(.*)$")
        tags[name] = value
    end

    return str, tags
end

---Turns a MoneyMoney transaction object into the parts of
---a ledger transaction string; separate header and posting
---for split transaction support (header is shared)
---
---@param transaction Transaction
---@param options table<string, boolean> Export options from the `Exporter` constructor
---@return LedgerTransaction transaction Header, posting and optional error
---@return string hash SHA1 hash of the header and error for group matching
function processTransaction(transaction, options)
    local transactionError

    -- ensure that the transaction has a category
    local category = transaction.category
    if category == "" then
        category = "Unknown"

        -- treat the missing category as an error if requested by the user
        if options.needsCategory == true then
            transactionError = localizeText(
                "The transaction does not have an assigned category",
                "Der Umsatz hat keine zugewiesene Kategorie"
            )
        end
    end

    -- ensure that the transaction is checked (if requested by the user)
    if options.needsCheckmark == true and transaction.checkmark == false then
        transactionError = transactionError
            or localizeText("The transaction was not checked", "Der Umsatz ist nicht als erledigt markiert")
    end

    -- status character (with trailing space only when present
    -- so that an empty character won't produce two spaces)
    local statusCharacter = ""
    if transaction.checkmark == true then
        statusCharacter = "* "
    elseif transaction.booked == false then
        statusCharacter = "! "
    end

    -- extract the counter account and list of tags from the category
    local counterAccountHierarchy, tags = parseCategory(category)
    local counterAccount = table.concat(counterAccountHierarchy, ":")
    if counterAccount == "" then
        -- the category name is so invalid that it made the account name empty;
        -- treat as high-priority error that overrides previous errors
        transactionError = localizeText(
            "Empty counter account from category '" .. category .. "'",
            "Leeres Gegenkonto aus der Kategorie '" .. category .. "'"
        )

        -- continue with a placeholder name for the output file
        counterAccount = "Invalid"
    end

    -- extract the comment and list of tags from the transaction comment
    local comment, transactionTags = parseTags(transaction.comment:gsub("\n", " "), true)
    if comment ~= "" then
        transactionTags.comment = comment
    end

    -- convert the purpose text to a tag, but only if the
    -- transaction comment did not override the purpose tag
    if transaction.purpose ~= "" and transactionTags.purpose == nil then
        transactionTags.purpose = transaction.purpose:gsub("\n", " ")
    end

    -- merge the transaction tags into the existing list
    -- (with precendence of the more specific transaction tags)
    for key, value in pairs(transactionTags) do
        tags[key] = value
    end

    -- separate handling of the `[date]`, `{tax}` and `<code>` tags
    -- as they will not be set as transaction tags but
    -- as posting tags or in the transaction header
    local postingTags = {}
    local code = ""
    if tags.date then
        -- literal tag without key
        table.insert(postingTags, tags.date)
        tags.date = nil
    end
    if tags.tax then
        postingTags.tax = tags.tax
        tags.tax = nil
    end
    if tags.code then
        code = "(" .. tags.code .. ") "
        tags.code = nil
    end

    -- flip the amount as we print it for the counter account;
    -- the format uses an ASCII space to enable commodity parsing in ledger/hledger
    local amount = MM.localizeAmount("#,##0.00 ¤;-#,##0.00 ¤", -transaction.amount, transaction.currency)

    -- assemble the transaction strings
    local ledgerTransaction = {
        header = (
            os.date("%Y-%m-%d", transaction.bookingDate)
            .. "="
            .. os.date("%Y-%m-%d", transaction.valueDate)
            .. " "
            .. statusCharacter
            .. code
            .. transaction.name
            .. formatTags(tags, "\n  ", "\n  ")
        ),
        posting = (counterAccount:gsub("%s+", " ") .. "  " .. amount .. formatTags(postingTags, "\n    ", " ")),
        error = transactionError,
    }

    -- transactions with different headers or different errors are not grouped
    local hash = MM.sha1(ledgerTransaction.header .. "//" .. (transactionError or "no error"))

    return ledgerTransaction, hash
end

---Removes spaces from the beginning and end of a string
---
---@param str string
---@return string
function trim(str)
    return str:match("^%s*(.-)%s*$")
end
