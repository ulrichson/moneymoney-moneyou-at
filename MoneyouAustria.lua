WebBanking {
  version = 1.1,
  url = "https://secure.moneyou.at/cwsoft/policyenforcer/pages/loginB2C.jsf",
  services = {"Moneyou Austria"},
  description = string.format(MM.localizeText("Get balance and transactions for %s"), "Moneyou Austria")
}

local debug = false
local overviewPage
local token
local ignoreSince = false -- ListAccounts sets this to true in order to get all transaction in the past

-- convert German localized amount string to number object
local function strToAmount(str)
  str = string.gsub(str, "[^-,%d]", "")
  str = string.gsub(str, ",", ".")
  return tonumber(str)
end

-- convert German localized date string to date object
local function strToDate(str)
  local d, m, y = string.match(str, "(%d%d)-(%d%d)-(%d%d%d%d)")
  if d and m and y then
    return os.time {year = y, month = m, day = d, hour = 0, min = 0, sec = 0}
  end
end

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Moneyou Austria"
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  local loginPage

  connection = Connection()
  loginPage = HTML(connection:get(url))
  loginPage:xpath("//*[@id='j_username_pwd']"):attr("value", username)
  loginPage:xpath("//*[@id='j_password_pwd']"):attr("value", password)

  for word in loginPage:xpath("/html/head"):text():gmatch("tokenValue = '.+'") do
    token = word:sub(15, #word - 1)
  end

  if token then
    loginPage:xpath("//*[@name='CW_TOKEN']"):attr("value", token)
    overviewPage = HTML(connection:request(loginPage:xpath("//*[@id='btnNext']"):click()))

    local errorMessage = overviewPage:xpath("//*[@class='logOffMessage']/span"):text()

    if string.len(errorMessage) > 0 then
      MM.printStatus("Login failed")
      return errorMessage
    else
      MM.printStatus("Login successful")
    end
  else
    MM.printStatus("Login failed")
    return "Could not retrieve token"
  end
end

function ListAccounts(knownAccounts)
  local accounts = {}

  -- Ignore since date when for first import
  ignoreSince = true

  -- Navigate to "Tagesgeld" / "Festgeld" and parse accounts
  overviewPage:xpath("//*[@id='clientOverviewAssetForm:depositsList']/tbody/tr"):each(
    function(index, element)
      local type

      if element:xpath("td[1]//span"):text() == "Tagesgeld" then
        type = AccountTypeSavings
      elseif element:xpath("td[1]//span"):text() == "Festgeld" then
        type = AccountTypeFixedTermDeposit
      end

      if type then
        local accountPage = HTML(connection:get(element:xpath("td[1]/a"):attr("href")))
        accountPage:xpath("//*[@id='PrincipalToCashAccountLinkForm:savingAccountList']/tbody/tr"):each(
          function(index, element)
            local account = {
              name = element:xpath("td[1]//span"):text(),
              iban = element:xpath("td[2]//span"):text(),
              accountNumber = element:xpath("td[2]//span"):text(),
              currency = "EUR",
              type = type
            }

            if debug then
              print("Fetched account:")
              print("  Name:", account.name)
              print("  Number:", account.accountNumber)
              -- print("  BIC:", account.bic)
              print("  IBAN:", account.iban)
              print("  Currency:", account.currency)
              print("  Type:", account.type)
            end

            table.insert(accounts, account)
          end
        )
      end
    end
  )

  return accounts
end

function RefreshAccount(account, since)
  local balance
  local transactions = {}

  local transactionPage =
    HTML(
    connection:get(
      "https://secure.moneyou.at/cwsoft/cashaccounting-b2c/pages/accountingMovementB2CListSelect01.jsf?chainingAction=true&WTRS=CGCL02&MENU=true"
    )
  )

  -- Select account
  local selectedAccount =
    transactionPage:xpath("//*[@id='accountNumber']/optgroup/option[contains(text(), '" .. account.iban .. "')]")
  transactionPage:xpath("//*[@id='accountNumber']"):select(selectedAccount:attr("value"))

  -- Get balance
  local balance = 0
  local balanceStr = selectedAccount:text()

  local i, s = balanceStr:find(account.name)
  local e, j = balanceStr:find(account.currency)
  if s ~= nil and e ~= nil then
    balance = strToAmount(balanceStr:sub(s + 2, e - 2))
  end

  if debug then
    print("Balance: " .. balance)
  end

  -- Select since date
  transactionPage:xpath("//*[@id='minimumDate']"):attr(
    "value",
    ignoreSince and "01-01-1970" or MM.localizeDate("dd-MM-yyyy", since)
  )

  -- Load transactions
  transactionPage:xpath("//*[@name='CW_TOKEN']"):attr("value", token)
  transactionPage = HTML(connection:request(transactionPage:xpath("//*[@id='btnNext']"):click()))
  transactionPage:xpath("//*[@id='AccountingMovementForm:summaryFiles']/tbody/tr"):each(
    function(index, element)
      local bookingDate = strToDate(element:xpath("td[1]//span"):text())

      if bookingDate ~= nil and (ignoreSince or bookingDate >= since) then
        local transaction = {
          bookingDate = bookingDate,
          valueDate = strToDate(element:xpath("td[2]//span"):text()),
          bookingText = element:xpath("td[3]//span"):text(),
          name = element:xpath("td[4]//span"):text(),
          amount = strToAmount(element:xpath("td[5]//span"):text()),
          currency = "EUR",
          booked = true
        }

        if debug then
          print("Transaction:")
          print("  Booking Date:", transaction.bookingDate)
          print("  Value Date:", transaction.valueDate)
          print("  Amount:", transaction.amount)
          print("  Currency:", transaction.currency)
          print("  Booking Text:", transaction.bookingText)
          print("  Purpose:", (transaction.purpose and transaction.purpose or "-"))
          print("  Name:", (transaction.name and transaction.name or "-"))
          print("  Bank Code:", (transaction.bankCode and transaction.bankCode or "-"))
          print("  Account Number:", (transaction.accountNumber and transaction.accountNumber or "-"))
        end

        table.insert(transactions, transaction)
      end
    end
  )
  return {balance = balance, transactions = transactions}
end

function EndSession()
  overviewPage:xpath("//*[@class='logOff']"):click()
end
