# DuoDisplay

Ein Mac per **Thunderbolt-Kabel** als zweiter Bildschirm des anderen, ausgelegt auf minimale Latenz. Per Tastenkürzel **⌃⌥⌘D** schaltest du jederzeit um, **⌃⌥⌘P** zeigt den MacBook-Bildschirm als Bild-in-Bild auf dem iMac.

Beispiel: MacBook links, iMac rechts, Magic Keyboard und Magic Trackpad am iMac.

| Modus | iMac zeigt | Tastatur und Trackpad des iMac steuern |
|---|---|---|
| **Zweiter Bildschirm** | einen zusätzlichen Bildschirm des MacBook | das MacBook, inklusive Gesten. Der Zeiger wandert nach links auf den MacBook-Bildschirm |
| **Normal nutzen** | seinen eigenen Schreibtisch | den iMac. Schiebst du den Zeiger über den linken Rand, steuern sie das MacBook, bis er über dessen rechten Rand zurückkommt |

Dieselbe App läuft auf beiden Macs. Sie lebt in der Menüleiste und bleibt dauerhaft gekoppelt. Im Dock erscheint sie nur, solange das DuoDisplay-Fenster (Einstellungen, Modus) offen ist. Geöffnet wird es über das Menüleisten-Symbol oder durch erneutes Öffnen der App im Finder. Das App-Icon liegt in `Resources/AppIcon.icon` und lässt sich mit Icon Composer (in Xcode enthalten) bearbeiten. `build.sh` übersetzt es mit `actool` aus Xcode. Ohne Xcode wird die fertige Fassung aus `Resources/AppIconCompiled` verwendet.

**Ton, Kamera und Mikrofon:**

- **Ton:** Im Bildschirm-Modus spielt der Ton des MacBook über die Lautsprecher des iMac. Das MacBook ist dann stumm. Die Lautstärketasten der Tastatur regeln dann die Lautstärke des iMac.
- **Kamera und Mikrofon:** Auf dem MacBook gibt es zwei neue Geräte, **„iMac-Kamera (DuoDisplay)“** und **„iMac-Mikrofon (DuoDisplay)“**. Sie lassen sich in FaceTime, Zoom, Teams usw. auswählen.
- Kamera und Mikrofon des iMac laufen nur, solange eine App auf dem MacBook sie benutzt.

## Bauen

Es reichen die Command Line Tools (kein Xcode nötig), macOS 14 oder neuer:

```bash
./build.sh
```

Ergebnis: `build/DuoDisplay.app`. Kopiere die App auf beide Macs nach `/Programme`.
Wenn macOS die kopierte App auf dem zweiten Mac blockiert („nicht verifizierter Entwickler“):

```bash
xattr -dr com.apple.quarantine /Applications/DuoDisplay.app
```

## Einrichten (einmalig)

1. **Kabel:** Beide Macs mit einem Thunderbolt-3/4/5- oder USB4-Kabel verbinden. macOS richtet die *Thunderbolt Bridge* automatisch ein.
   Empfohlen auf *beiden* Macs: Systemeinstellungen → Netzwerk → Thunderbolt Bridge → Details → Hardware → Konfigurieren *Manuell*, MTU *Jumbo (9000)*.
2. **Universal Control ausschalten** (empfohlen): DuoDisplay bringt den Wechsel über den Bildschirmrand selbst mit. Ist Universal Control zusätzlich an, reagieren beide am selben Rand. Ausschalten auf beiden Macs unter Systemeinstellungen → Displays → Erweitert → „Zeiger und Tastatur zwischen Mac und iPad bewegen“.
3. **iMac:** DuoDisplay öffnen → *Als Bildschirm verwenden*.
4. **MacBook:** DuoDisplay öffnen → *Bildschirm erweitern*. Bei *„Der andere Mac steht“* die Option *rechts* wählen, dann beim iMac auf **Verbinden** klicken.
   **Koppeln:** Beide Macs zeigen jetzt ein Fenster mit einem 6-stelligen Code. Steht auf beiden derselbe Code, auf beiden **Koppeln** klicken.
   Ab jetzt verbindet sich das MacBook automatisch, auch nach Neustart oder erneutem Einstecken. Es startet dann im Modus „Normal nutzen“.
   War einer der beiden Macs schon mit einem anderen gekoppelt, dort zuerst *Kopplung aufheben* wählen – ein gekoppelter Mac nimmt keine neue Kopplung an.
5. **iMac-Mikrofon** (MacBook): DuoDisplay → *Ton, Kamera & Mikrofon* → *iMac-Mikrofon* → **Installieren…**
   macOS fragt nach dem Administrator-Passwort. Der Treiber wird nach `/Library/Audio/Plug-Ins/HAL` kopiert und Core Audio neu gestartet.
6. **iMac-Kamera** (MacBook): **Kamera-Erweiterung aktivieren…**
   Danach unter Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Kamera-Erweiterungen erlauben. Das geht nur mit einer passend signierten App, siehe [Virtuelle Kamera](#virtuelle-kamera-signatur-mit-apple-developer-konto).
7. **iMac:** Im Bereich *Kamera & Mikrofon für das MacBook* Kamera und Mikrofon erlauben.

### Entfernen

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/DuoDisplayMic.driver && sudo killall coreaudiod
```

Die Kamera-Erweiterung verschwindet, wenn du DuoDisplay aus `/Programme` in den Papierkorb legst.

### Berechtigungen

| Mac | Berechtigung | Wofür |
|---|---|---|
| beide | **Lokales Netzwerk** | Verbindung über Thunderbolt |
| beide | **Bedienungshilfen** | iMac: Eingaben abfangen · MacBook: Eingaben einspielen und Zeiger verfolgen |
| MacBook | **Bildschirm- & Systemaudioaufnahme** | den zusätzlichen Bildschirm aufnehmen |
| MacBook | **Nur Systemaudioaufnahme** | Ton zum iMac schicken (macOS fragt beim ersten Bildschirm-Modus) |
| MacBook | **Kamera** | Bilder an die virtuelle iMac-Kamera weitergeben |
| iMac | **Kamera**, **Mikrofon** | Kamerabild und Ton an das MacBook schicken |

Die App zeigt an, was noch fehlt, und hat einen Button zum Erlauben.

### Signatur (damit Freigaben Updates überstehen)

`build.sh` signiert mit dem selbst erstellten Zertifikat **„DuoDisplay Local Signing“**. macOS knüpft die Freigaben an App-ID und Zertifikat, also bleiben sie bei jedem neuen Build erhalten.

- Zertifikat und Schlüssel liegen in einem **eigenen Schlüsselbund** `~/Library/Keychains/duodisplay-signing.keychain-db`, nicht im Anmelde-Schlüsselbund.
- Dessen zufälliges Passwort steht in `~/Library/Application Support/DuoDisplay/signing-keychain-password` (nur für dich lesbar). `build.sh` entsperrt damit den Schlüsselbund ohne Rückfrage.
- Das Zertifikat ist selbst signiert und 10 Jahre gültig. Es taugt nur für deine eigenen Macs; Gatekeeper behandelt die App weiterhin als „nicht verifiziert“ (daher der `xattr`-Befehl).
- Entfernen: `security delete-keychain ~/Library/Keychains/duodisplay-signing.keychain-db` und den Ordner `~/Library/Application Support/DuoDisplay` löschen. Danach signiert `build.sh` wieder ad-hoc.
- Eigenes Apple-Zertifikat statt dessen: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

### Virtuelle Kamera: Signatur mit Apple-Developer-Konto

Die iMac-Kamera ist eine **Kamera-Erweiterung** (Core Media I/O, Systemerweiterung). macOS aktiviert so etwas nur bei einer App, die mit einem Apple-Zertifikat **und** Provisioning-Profilen signiert ist. Das selbst erstellte Zertifikat reicht dafür nicht. Ton und Mikrofon funktionieren auch ohne.

**Voraussetzung:** ein Apple-Developer-Konto (99 €/Jahr).

1. **Zertifikat:** Xcode öffnen → Einstellungen → Accounts → mit der Apple-ID anmelden → Team wählen → *Manage Certificates…* → **+** → *Apple Development*. Prüfen:
   ```bash
   security find-identity -v -p codesigning
   ```
2. **Beide Macs registrieren** (Certificates, IDs & Profiles → Devices → +, Plattform macOS). Die Kennung zeigt auf jedem Mac:
   ```bash
   system_profiler SPHardwareDataType | grep "Provisioning UDID"
   ```
3. **Zwei App-IDs** (Identifiers → + → App IDs → App):
   - `local.duodisplay.DuoDisplay`, Fähigkeit **System Extension**
   - `local.duodisplay.DuoDisplay.CameraExtension`, Fähigkeit **App Groups**
4. **Zwei Profile** (Profiles → + → *macOS App Development*): je eines pro App-ID, mit deinem Zertifikat und beiden Macs. Herunterladen.
5. **Bauen:**
   ```bash
   SIGN_IDENTITY="Apple Development: Dein Name (XXXXXXXXXX)" \
   APP_PROFILE=~/Downloads/DuoDisplay.provisionprofile \
   CAMERA_PROFILE=~/Downloads/DuoDisplayCamera.provisionprofile \
   ./build.sh
   ```
   Liegen die Profile als `DuoDisplay_Development.provisionprofile` und `DuoDisplay_Camera_Development.provisionprofile` in `~/Library/Application Support/DuoDisplay/apple-dev/`, reicht ein einfaches `./build.sh`: Zertifikat und Profile werden dann automatisch verwendet.
   `build.sh` prüft, ob die Profile zu den App-IDs passen und diesen Mac enthalten. Die Team-ID liest es aus dem Zertifikat (sonst `TEAM_ID=…`). Lehnt Apple die Bundle-ID ab, nimm eine eigene, etwa `BUNDLE_ID=de.deinname.DuoDisplay`, und passe die App-IDs an.
6. Die App auf beiden Macs nach `/Programme` kopieren (Pflicht für Systemerweiterungen). Auf dem MacBook *Kamera-Erweiterung aktivieren…* klicken.

Durch das neue Zertifikat fragt macOS einmal neu nach den Freigaben (Bedienungshilfen, Bildschirmaufnahme usw.).

## Benutzen

- **⌃⌥⌘D** auf iMac oder MacBook schaltet um. Alternativ geht das über das Menüleisten-Symbol oder den Umschalter im Fenster.
- Im Bildschirm-Modus wird alles von Tastatur und Trackpad des iMac an das MacBook weitergegeben: Tippen, Klicken, Rechtsklick, Ziehen, Scrollen mit Schwung, Zoomen/Drehen, Force Touch, Wischgesten, ⌘-Tab, Spotlight, Medientasten (Lautstärke siehe *Lautstärke* weiter unten).
- Beim Wechsel in den Bildschirm-Modus springt der Zeiger in die Mitte des iMac-Bildschirms.
- Beim Wechsel zu „Normal nutzen“ verschwindet der zusätzliche Bildschirm. Seine Fenster wandern aufs MacBook.
- Gedrückt gehaltene Tasten und Maustasten werden beim Umschalten automatisch losgelassen. So bleibt nichts „hängen“.
- **Maus über den Rand (Modus „Normal nutzen“):** Schiebe den Zeiger am linken Rand des iMac ein Stück weiter. Er erscheint dann am rechten Rand des MacBook auf derselben relativen Höhe. Ab da steuern Maus, Trackpad und Tastatur des iMac das MacBook, inklusive Gesten und Kurzbefehlen. Schiebst du den Zeiger über den rechten Rand des MacBook hinaus, kommt er am linken Rand des iMac wieder heraus und alles gilt wieder für den iMac.
  - Ein kleiner Widerstand (6 pt) verhindert versehentliches Wechseln, wenn du etwas direkt am Rand anklickst.
  - Mit gedrückter Maustaste (beim Ziehen eines Fensters, einer Datei, von Text) bleibt der Zeiger am Rand stehen.
  - Steht der iMac links vom MacBook, gilt alles spiegelverkehrt.
  - Ein- und ausschalten auf dem MacBook: *„Normal nutzen“: Mit der Maus über den Rand des iMac aufs MacBook wechseln*. Das braucht dort die Freigabe *Bedienungshilfen*, sonst bleibt es aus.
  - Das Tastenkürzel ⌃⌥⌘D auf dem iMac holt Maus und Tastatur sofort zurück. Antwortet das MacBook 1,5 s lang nicht oder bricht die Verbindung ab, passiert das automatisch.
- **Bild-in-Bild (⌃⌥⌘P, Modus „Normal nutzen“):** Der Bildschirm des MacBook erscheint auf dem iMac in einem kleinen schwebenden Fenster (auf allen Spaces, über allen Fenstern). ⌃⌥⌘P auf einem der beiden Macs (oder das Menüleisten-Symbol) blendet es ein und aus. Im Bildschirm-Modus schaltet ⌃⌥⌘P auf „Normal nutzen“ mit offenem Bild-in-Bild.
  - **Gespiegelt oder erweitert:** Rechts in der Titelleiste des Fensters wählst du *Gespiegelt* (der Bildschirm des MacBook selbst) oder *Erweitert* (ein zusätzlicher Bildschirm des MacBook, so groß wie sein eigener). Das Umschalten geht bei offenem Bild sofort, der iMac merkt sich die Wahl. Der zusätzliche Bildschirm liegt auf der vom iMac abgewandten Seite des MacBook, damit der Wechsel über den Bildschirmrand weiter auf dem MacBook-Bildschirm landet. Schließt du das Bild oder schaltest auf *Gespiegelt*, wandern seine Fenster aufs MacBook.
  - **Hinein:** Schiebe den iMac-Zeiger von einer beliebigen Seite ins Bild. Der MacBook-Zeiger springt an dieselbe Stelle, und ab da steuern Maus, Trackpad und Tastatur des iMac das MacBook, inklusive Gesten und Kurzbefehlen.
  - **Hinaus:** Schiebe den Zeiger über einen beliebigen Rand des MacBook-Bildschirms. Der iMac-Zeiger erscheint direkt neben dem Fenster an der passenden Stelle, die Bewegung läuft weiter. Wie am Bildschirmrand gibt es einen kleinen Widerstand (6 pt), damit Menüleiste, Dock und heiße Ecken des MacBook erreichbar bleiben. Mit gedrückter Taste (beim Ziehen) bleibt der Zeiger im Bild.
  - **Tempo:** Der Zeiger bewegt sich im Bild so schnell wie deine Hand auf dem iMac. Bei einem Bild halb so breit wie der MacBook-Bildschirm legt der MacBook-Zeiger also die doppelte Strecke zurück.
  - **Verschieben und Größe:** an der Titelleiste ziehen bzw. an den Seiten und Ecken. Das Seitenverhältnis bleibt das des MacBook, Position und Größe merkt sich der iMac. Damit das Ziehen am Rand nicht ins MacBook springt, beginnt der Bereich, der übernimmt, 4 pt innerhalb des Bildes. Liegt ein Menü über dem Bild, übernimmt es dort nicht. Nach einem Klick in ein solches Menü übernimmt es erst wieder, wenn der Zeiger einmal hinaus und wieder hinein geschoben wird.
  - Steht der Zeiger schon im Bild, wenn es aufgeht (oder nach ⌃⌥⌘D), passiert erst etwas, wenn er einmal hinaus und wieder hinein geschoben wird.
  - ⌃⌥⌘D holt Tastatur und Zeiger sofort zurück, ⌃⌥⌘P schließt dabei das Bild.
  - Gezeigt wird der Hauptbildschirm des MacBook (der mit der Menüleiste) bzw. der zusätzliche Bildschirm, mit höchstens 1,5× und 60 Hz, ohne Ton. Codec, Bitrate und „Mauszeiger lokal zeichnen“ gelten wie im Bildschirm-Modus. Solange das Bild offen ist, nimmt das MacBook auf und kodiert; das kostet etwas Akku. Bei unverändertem Bildschirm entstehen fast keine Bilder.
  - Der iMac merkt sich, ob das Bild-in-Bild offen war, und öffnet es nach dem Verbinden oder nach dem Bildschirm-Modus wieder.
  - Steuern über das Bild braucht auf dem MacBook die Bedienungshilfen-Freigabe, das Bild selbst die Bildschirmaufnahme-Freigabe. Fehlt eine, zeigt der iMac einen Hinweis im DuoDisplay-Fenster.
- **Einstellungen** (Codec, Auflösung, Bildrate, Bitrate, Mauszeiger …) auf dem MacBook gelten sofort. Der Stream startet dabei kurz neu, der zusätzliche Bildschirm und seine Fenster bleiben, wo sie sind.
- **Codec:** *ProRes* ist der Standard und hat die geringste Verzögerung (siehe [Latenz](#latenz)), braucht aber rund 250–600 Mbit/s und damit Thunderbolt. Stelle dafür die MTU auf beiden Macs auf *Jumbo (9000)*, sonst werden es sehr viele kleine Pakete. Ohne Thunderbolt, ohne ProRes-Hardware auf einem der Macs oder mit einer älteren DuoDisplay-Version auf dem iMac nimmt DuoDisplay automatisch HEVC; die Detailzeile zeigt dann den Grund. *HEVC* braucht nur einen Bruchteil der Daten, ist aber rund 4 ms langsamer.
- **Bildrate:** Standard ist *„Wie der iMac“*, also 60 Hz. Der zusätzliche Bildschirm, die Aufnahme und der Encoder laufen dann genau so oft, wie der iMac Bilder zeigen kann. 120 Hz spart höchstens ein paar Millisekunden, verdoppelt aber die Arbeit des MacBook (4480×2520 Pixel bei einem 4,5K-iMac). Unter Last kamen so oft nur 18–30 Bilder/s an.
- **Automatische Auflösung:** Braucht der Encoder des MacBook zwei Sekunden lang über 20 ms pro Bild (unter ~50 Bilder/s), streamt DuoDisplay mit der nächstkleineren Stufe (2× → 1,5× → 1×). Der zusätzliche Bildschirm behält dabei seine Retina-Auflösung, nur das übertragene Bild wird kleiner. Das MacBook zeigt das in der Detailzeile an. Wählst du die Auflösung neu, wird wieder mit ihr begonnen.
- **Ton:** Der Schalter *„Ton im Bildschirm-Modus über den iMac abspielen“* auf dem MacBook ist an, wenn nichts anderes eingestellt ist. Bei „Normal nutzen“ klingt alles wieder aus dem MacBook.
- **Lautstärke:** Läuft der Ton über den iMac, bleiben *lauter*, *leiser* und *stumm* (auch mit ⇧⌥ für feine Schritte) im Bildschirm-Modus auf dem iMac. Sie regeln dessen Ausgabegerät, der iMac zeigt die Lautstärkeanzeige. Alle anderen Tasten gehen weiter ans MacBook. Ist der Ton-Schalter aus, steuern die Tasten wie bisher das MacBook. Bei „Normal nutzen“ (auch über den Rand oder im Bild-in-Bild) gilt die Lautstärke des Mac, der gerade gesteuert wird.
- **Videocall auf dem MacBook:** In der App als Kamera „iMac-Kamera (DuoDisplay)“ und als Mikrofon „iMac-Mikrofon (DuoDisplay)“ wählen. Der Gesprächston kommt im Bildschirm-Modus automatisch aus dem iMac. Die Kamera läuft auch im Modus „Normal nutzen“, solange die Macs gekoppelt sind.

**Notausgang:** ⌃⌥⌘D wird *immer* direkt auf dem iMac ausgewertet und nie weitergeleitet. Das funktioniert auch, wenn das MacBook nicht antwortet. Bricht die Verbindung ab, bekommt der iMac seine Eingaben sofort zurück. Steuert der iMac gerade über den Rand das MacBook, holt ⌃⌥⌘D nur die Eingaben zurück; ein zweites ⌃⌥⌘D schaltet in den Bildschirm-Modus.

## Latenz

**Video** (gemessen mit `--selftest` auf einem M4, Frame → dekodiert):

| Auflösung (Einstellung) | Encoder | Frame → dekodiert |
|---|---|---|
| Retina 2× (3024×1890) | 7,6 ms | ~11 ms |
| Retina 2×, **ProRes** (Standard) | 4,5 ms | ~7 ms (1400-B-Pakete: ~8,5 statt ~8,9 ms) |
| Ausgewogen 1,5× | 5,1 ms | ~7 ms |
| Schnell 1× @120 Hz | 2,9 ms | ~4,4 ms |

**ProRes oder HEVC** (M4, 3024×1890, 60 Bilder/s, scrollender Text, alles in Hardware):

| Codec | Kodieren | Dekodieren | Daten |
|---|---|---|---|
| HEVC | Ø 9,1 ms | Ø 3,5 ms (p95 6,5) | ~66 Mbit/s |
| ProRes 422 Proxy | Ø 4,8 ms | Ø 1,6 ms (p95 2,0) | ~260 Mbit/s |
| H.264 | Ø 14,2 ms | Ø 4,0 ms | ~40 Mbit/s |

Ein ProRes-Bild sind ~420 KB, also ~50 Jumbo- oder ~300 normale Pakete. Der Mac sendet sie direkt per `sendmsg` (ohne Network.framework-Warteschlange), der iMac setzt sie ohne Umkopieren zusammen und ist ~0,1 ms nach dem letzten Paket fertig. Vorher kostete das Zusammensetzen bei 300 Paketen ~3 ms.

Jedes Paket ist mit AES-GCM verschlüsselt (siehe [Kopplung](#kopplung-und-sicherheit)). Ein einzelner Kern bräuchte dafür bei 60 Bildern/s ~0,7 ms pro ProRes-Bild in Jumbo- und ~2,3 ms in 1400-B-Paketen, auf jeder Seite (zwischen den Bildern taktet er herunter). Deshalb verschlüsselt der Sender große Bilder portionsweise auf mehreren Kernen und schickt jede Portion ab, sobald sie fertig ist. Der Empfänger entschlüsselt alle schon angekommenen Pakete gemeinsam auf mehreren Kernen.

`--transporttest` misst, was davon übrig bleibt (420-KB-Bild, ohne Encoder und Decoder): Zwischen zwei Macs sind es geschätzt ~+0,3 ms pro ProRes-Bild mit Jumbo-Paketen und ~+0,1–0,6 ms mit 1400-B-Paketen. Die Schätzung stammt aus Messungen je einer Seite und ist noch nicht mit zwei Macs geprüft. Im `--selftest`, wo beide Seiten auf einem Mac laufen, liegt ProRes mit Jumbo-Paketen bei ~7,0–7,3 ms wie vor der Verschlüsselung. Mit 1400-B-Paketen sind es dort ~9,5 statt ~7,6–8,2 ms, weil sich Sender und Empfänger dieselben Kerne teilen. Bei HEVC ist kein Unterschied messbar.

Bei ProRes steht jedes Bild für sich. Geht ein Paket verloren, fehlt genau dieses eine Bild; bei HEVC wartet der iMac auf ein neues Keyframe (im Selbsttest bis zu ~70 ms). Der iMac dekodiert ProRes direkt ins 4:2:2-Format, eine Umwandlung in 4:2:0 würde ~2,6 ms kosten.

Dazu kommen die Bildschirmaufnahme und bis zu ein Bildaufbau des Displays (16,7 ms bei 60 Hz). Die Live-Latenz „Aufnahme → Empfang“ zeigt die App im Fenster an.

Der Hardware-Decoder des iMac läuft ohne Stromspar-Hinweis (`1xRealTimePlayback`). Mit diesem Hinweis brauchte er bei scrollendem Text Ø 6,3 ms (p95 13 ms) pro Bild statt Ø 3,7 ms (p95 6,7 ms).
Solange die Macs verbunden sind, schützen sich beide Apps vor App Nap. Sonst würde macOS die fensterlosen Menüleisten-Apps im Modus „Normal nutzen“ drosseln und weitergeleitete Eingaben verzögern. Der Ruhezustand bleibt dabei erlaubt.

Beide Macs schreiben die Werte jede Sekunde ins Systemprotokoll. Der iMac protokolliert auch die Werte des MacBook (Zeilen „MacBook: …“: Auflösung, Hz, Encoder, Aufnahmeverzögerung):

```bash
log show --last 10m --info --style compact --predicate 'subsystem == "local.duodisplay"'
```

**Mauszeiger:** Mit *„Mauszeiger lokal zeichnen“* (Standard) schickt das MacBook nur Position und Form des Zeigers. Der iMac zeichnet ihn selbst über das Video. Der Zeiger folgt deiner Hand also mit Netzwerk-Latenz (unter 1 ms über Thunderbolt) statt mit Video-Latenz.

Der Zeiger ist eine eigene kleine Core-Animation-Ebene über dem Video, die nur verschoben wird. Früher wurde für jede Zeigerbewegung das ganze 4,5K-Bild neu gezeichnet. Der WindowServer gibt aber nur etwa zwei Metal-Puffer pro Bildaufbau frei, und eine Maus meldet 125–1000 Positionen pro Sekunde. Deshalb wartete jedes neue Videobild im Schnitt ~6 ms auf einen freien Puffer, sobald sich der Zeiger bewegte. Jetzt wird nur für Videobilder gezeichnet (`--rendertest --window`, ProRes, Zeiger mit 480 Hz: Frame → GPU Ø 6,2 statt ~10 ms; HEVC 10,5 statt 14 ms).

**Ton:** Unkomprimiert (16 Bit, Pakete zu 5 ms) über UDP. Der iMac puffert 20 ms. Kleine Taktunterschiede zwischen den Macs gleicht er unhörbar aus, indem er einzelne Samples auslässt oder doppelt abspielt. Insgesamt sind es etwa 30–40 ms. Für das Mikrofon puffert das MacBook 25 ms.

**Kamera:** 1080p, 30 fps, HEVC mit 12 Mbit/s. Das MacBook dekodiert in Hardware direkt auf das Format der virtuellen Kamera.

**Eingaben:** Die Events gehen als Original-Bytes (`CGEventCreateData`) über eine TCP-Verbindung mit `TCP_NODELAY`. Scroll-Phasen, Schwung, Klickanzahl und Gesten-Daten bleiben dabei exakt erhalten. Das prüft `--inputtest`.

## Wie es funktioniert

```
iMac (Bildschirm-Modus)                         MacBook
Event-Tap (HID-Ebene) fängt alle Eingaben ab ──► CGEventPost (Zeigerposition neu berechnet)
                                                 CGVirtualDisplay rechts vom Hauptbildschirm
Vollbild-Fenster ◄── UDP-Video (HEVC/ProRes) ─── ScreenCaptureKit → VideoToolbox
  + lokal gezeichneter Zeiger ◄── Position/Form ─ Event-Tap (nur lesen) + NSCursor
Lautsprecher ◄── UDP-Ton (PCM, 5-ms-Pakete) ────── Core-Audio-Tap (MacBook lokal stumm)
Kamera → HEVC ── UDP ──────────────────────────► Dekoder → Kamera-Erweiterung → „iMac-Kamera“
Mikrofon ─────── UDP-Ton ──────────────────────► Loopback-Treiber → „iMac-Mikrofon“
          ◄── TCP-Steuerkanal (gekoppelt, verschlüsselt): Modus, Keyframes, Ping, Statistik, ──►
                    Kamera/Mikrofon gebraucht?, Ton über den iMac? (dann bleiben die Lautstärketasten dort)

iMac (Normal nutzen)                            MacBook
Event-Tap (nur lesen) sieht Zeiger am Rand ────► edgeEnter → Zeiger an den rechten Rand
Event-Tap (HID-Ebene) fängt alle Eingaben ab ──► CGEventPost wie im Bildschirm-Modus
Zeiger erscheint wieder am linken Rand ◄──────── edgeLeave, sobald der Zeiger rechts hinausgeschoben wird

iMac (Normal nutzen, Bild-in-Bild ⌃⌥⌘P)          MacBook
pipStart ───────────────────────────────────────► Hauptbildschirm aufnehmen (≤ 1,5×, ≤ 60 Hz)
schwebendes Fenster ◄── UDP-Video + Zeiger ────── ScreenCaptureKit → VideoToolbox, pipState (Größe)
Zeiger bewegt sich ins Bild ───────────────────► edgeEnter(x, y, Tempo) → Zeiger an dieselbe Stelle
Event-Tap (HID-Ebene) fängt alle Eingaben ab ──► CGEventPost, Zeiger bleibt auf dem Hauptbildschirm
Zeiger erscheint neben dem Fenster ◄──────────── edgeLeave(x, y, Seite), sobald er über einen Rand geschoben wird
```

## Kopplung und Sicherheit

Nur der Mac, mit dem du gekoppelt hast, kann sich verbinden. Ein anderes Gerät im WLAN kann den iMac also weder übernehmen noch deine Eingaben, deinen Bildschirm oder Kamera und Mikrofon mitlesen oder verändern.

- **Koppeln** passiert beim ersten *Verbinden*. Beide Macs zeigen einen 6-stelligen Code, du bestätigst auf beiden. Ein Gerät, das sich dazwischenschalten will, kann nicht dafür sorgen, dass beide Codes gleich sind.
- **Bestätige nur**, wenn du die Verbindung gerade selbst gestartet hast und auf beiden Macs derselbe Code steht. Kommt die Anfrage nicht über das Thunderbolt-Kabel (z. B. über WLAN), steht im Fenster ein Warnhinweis.
- Der gemeinsame Schlüssel liegt im **Schlüsselbund** (Eintrag „DuoDisplay Kopplung“). Jeder Mac merkt sich genau einen Partner.
- **Ein gekoppelter Mac nimmt keine neue Kopplung an.** Ein fremdes Gerät im Netz kann auf einem gekoppelten iMac also nicht einmal das Kopplungsfenster öffnen, und ein falscher „iMac“ kann ein gekoppeltes MacBook nicht übernehmen. Zum Koppeln mit einem anderen Mac zuerst *Kopplung aufheben*.
- Bei jeder Verbindung weisen sich beide Macs mit diesem Schlüssel aus und leiten daraus neue Schlüssel nur für diese Verbindung ab. Damit ist der **Steuerkanal** (Tastatur, Maus, Modus, Zeiger) mit AES-GCM verschlüsselt und gegen Verändern geschützt, ebenso **Bild, Ton, Kamera und Mikrofon** (jedes UDP-Paket einzeln, mit eigenem Schlüssel je Richtung). Pakete von anderen Absendern, veränderte und wiederholte Pakete verwirft der Empfänger, bevor sie Bildschirm, Lautsprecher, Kamera oder Mikrofon erreichen; ohne Verbindung nimmt er gar keine an.
- **Kopplung aufheben:** im DuoDisplay-Fenster auf dem jeweiligen Mac. Danach muss neu gekoppelt werden.
- Läuft auf einem Mac noch eine ältere DuoDisplay-Version, kommt keine Verbindung zustande – beide Macs aktualisieren.
- Wird ein Kopplungsversuch am iMac abgelehnt, nimmt er 10 Sekunden lang keinen neuen an. Im Bildschirm-Modus nimmt er gar keinen an.

## Grenzen und bekannte Risiken

- **Systemgesten (Spaces wischen, Mission Control, App-Exposé):** Die Events werden abgefangen und mit allen Feldern übertragen. *Ob* der iMac sie dabei selbst ignoriert und das MacBook sie ausführt, hängt davon ab, wie macOS sie intern weiterleitet. Das konnte ich ohne zwei Macs nicht testen. Falls der iMac trotzdem Spaces wechselt, bleibt das DuoDisplay-Fenster dank „auf allen Spaces“ trotzdem sichtbar.
- **Maus über den Rand:** Solange das MacBook gesteuert wird, ist der iMac-Zeiger eingefroren und ausgeblendet. Das Ausblenden im Hintergrund nutzt eine private WindowServer-Einstellung (wie Synergy/Deskflow). Fehlt sie nach einem macOS-Update, bleibt der Zeiger am Rand sichtbar stehen; der Rest funktioniert weiter. Mit zwei echten Macs konnte ich das noch nicht testen.
- **Universal Control im Bildschirm-Modus:** Über das MacBook-eigene Trackpad nicht über den äußersten rechten Rand des iMac-Bildschirms hinausschieben. Sonst springt Universal Control in den (verdeckten) iMac. Weitergeleitete iMac-Eingaben sind davor geschützt: Der Zeiger bleibt 1 pt vor dem Rand.
- **Passwortfelder:** Wenn macOS *Secure Input* aktiviert (Passwortfelder, manche Terminals), blockiert es eingespielte Tastatureingaben. Das ist eine Sicherheitsfunktion von macOS.
- `CGVirtualDisplay` ist eine **private Apple-API** (wie bei DeskPad/BetterDisplay). Ein macOS-Update kann sie ändern.
- **Bild-in-Bild:** Mit zwei echten Macs konnte ich es noch nicht testen, nur Fenster, Erkennung und Geometrie auf einem Mac (`--piptest`, `--edgetest`). Hat das MacBook weitere Bildschirme, ist der Zeiger beim Steuern über das Bild auf den Hauptbildschirm beschränkt.
- **Ton-Abgriff:** Er nutzt das Ausgabegerät, das beim Wechsel in den Bildschirm-Modus eingestellt ist. Wenn du danach Kopfhörer am MacBook ansteckst, schalte einmal um (⌃⌥⌘D zweimal).
- **iMac-Mikrofon:** Es ist ein Mono-Gerät mit 48 kHz. Die Echounterdrückung macht die Videocall-App selbst, wie bei jedem USB-Mikrofon.

## Tests

```bash
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --selftest     # Video-Pipeline über Loopback inkl. Paketverlust
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --inputtest    # Eingabe-Events bleiben beim Übertragen vollständig, Lautstärketasten werden erkannt
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --pairtest     # Kopplung, Anmeldung, Verschlüsselung von Steuerkanal und Medienpaketen, keine Neu-Kopplung gekoppelter Macs (mit --keychain auch der Schlüsselbund)
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --displaytest  # virtueller Bildschirm: HiDPI-Modus und Position rechts
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --edgetest     # Maus über den Rand: Rand-Erkennung und Eintrittspunkt bei verschiedenen Anordnungen, Bild-in-Bild: hinein/hinaus an allen Seiten
open -n -W build/DuoDisplay.app --args --piptest /tmp/piptest.txt  # Bild-in-Bild-Fenster mit Testbild: Größe, Seitenverhältnis, Zeiger ins Bild von jeder Seite, nicht beim Ziehen, nicht unter Menüs (bewegt ~2 s den Zeiger; mit --env DD_PIP_HOLD=5 bleibt das Testbild 5 s stehen)
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --mediatest    # Ton-Pakete, fremde/wiederholte Pakete am UDP-Port, Jitter-Puffer mit Taktdrift, Kamera-Strecke, Wiedergabe
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --transporttest  # nur das Netz: ProRes-großes Bild verschlüsselt vs. unverschlüsselt, Aufschlag je Seite
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --rendertest --window  # Empfang im echten Fenster (60 fps + Zeiger mit 480 Hz, dann 120 fps): Verzögerung darf sich nicht aufstauen, Zeiger-Ebene sitzt richtig (mit --prores: ProRes statt HEVC)
build/DuoDisplay.app/Contents/MacOS/DuoDisplay --uisnapshot build/ui-snapshots  # alle Fenster (Modus-Wahl, MacBook, iMac, Kopplungscode) hell und dunkel als PNG, ohne zu verbinden
```

## Mitwirken

Beiträge sind willkommen, besonders Tests mit zwei echten Macs. Wie du baust, testest und Änderungen einreichst, steht in [CONTRIBUTING.md](CONTRIBUTING.md). Sicherheitslücken bitte nicht öffentlich melden, sondern wie in [SECURITY.md](SECURITY.md) beschrieben. Es gilt der [Code of Conduct](CODE_OF_CONDUCT.md). Änderungen je Version stehen im [CHANGELOG](CHANGELOG.md).

## Lizenz

[MIT](LICENSE). DuoDisplay nutzt private Apple-APIs (`CGVirtualDisplay`, eine WindowServer-Einstellung). Deshalb kann es nicht in den Mac App Store.
