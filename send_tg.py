import os,urllib.request,json

r = json.load(
    urllib.request.urlopen(f'https://api.telegram.org/bot{os.environ["TG_BOT_TOKEN"]}/getUpdates')
)
print(r['result'][-1]['message']['chat']['id'])