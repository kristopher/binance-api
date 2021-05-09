# WIP

See: https://github.com/binance-us/binance-official-api-docs/blob/master/rest-api.md

## Config

`
Binance.config = {
  api_key: 'api_key',
  secret_key: 'secret_key',
}
`

## Prices
`
Binance::MarketData.price('DOGEUSD')

  => 1.00
`

`
Binance::MarketData::DOGEUSD.price

  => 1.00
`

## Wallet
`
Binance::Wallet.coins => [<DOGE>, <BTC>]
`

## Spot Account

`
Binance::SpotAccount.create_order(...)
`

`
Binance::SpotAccount.get_order(...)
`