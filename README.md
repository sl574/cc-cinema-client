# cc-cinema-client (public mirror)

Плееры кинотеатра CC-Cinema для Minecraft (CC:Tweaked). Только код,
фильмы лежат в приватном репозитории.

```lua
wget https://raw.githubusercontent.com/sl574/cc-cinema-client/main/client/svideo.lua svideo.lua
wget https://raw.githubusercontent.com/sl574/cc-cinema-client/main/client/skino.lua skino.lua
```

Дальше нужен read-only токен приватного репозитория с фильмами:

```lua
svideo setup <token>
skino
```

## Отладка "пленки" / подергиваний

`svideo_dbg.lua` — тот же плеер, но с телеметрией в углу монитора
(`F<кадр> <K/R/D> d<dropped> l<late> s<stalls> q<очередь>`):

```lua
wget https://raw.githubusercontent.com/sl574/cc-cinema-client/main/client/svideo_dbg.lua svideo_dbg.lua
svideo_dbg <job_id>
```

В конце показа плеер печатает `done. dropped ... late ... stalls ... badRec ...`:

- `dropped` — кадры, примененные к базе без показа (комп/сервер не успевал);
- `late` — пробуждений видеопотока с отставанием больше кадра;
- `stalls` — тиков без данных (CDN/сеть не успевает);
- `badRec` — битых записей в потоке (должно быть 0).
