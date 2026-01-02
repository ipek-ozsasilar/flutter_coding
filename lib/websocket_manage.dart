/*
Client (senin Flutter app): connect() diyerek server’a bağlanmayı başlatır. Server (echo endpoint): Bu isteği kabul eder ve bağlantı kurulur.
Senin sınıfın yaptığı şey: client tarafında WebSocketChannel.connect(url) çağırıp, server’a “handshake” isteği atmak, kabul edilince de 
açık bağlantı üzerinden mesajları dinlemek. Yani “bağlantı açma” = Flutter’dan wss endpoint’e bağlanma. Şuan bu client yönetimi
Sen mesajı şuraya gönderdin: wss://echo.websocket.events adresindeki echo WebSocket server’a Bu server’ın işi şu: Gelen mesajı alır
Hiç işlem yapmadan aynısını geri yollar Yani “gerçek bir backend” değil; test server. send şunu temsil ediyor: Senin uygulamanın (client)
açık WebSocket bağlantısı üzerinden server’a bir “frame/mesaj” göndermesi recv = “receive”
Server’dan gelen mesajı temsil ediyor. Echo server olduğu için: sen ne gönderdiysen (sent) o sana aynı şeyi geri yolluyor (recv)

Gerçek sistemde recv şu olurdu:

“Yeni sipariş geldi”

“Order status changed”

“Chat mesajı geldi”

“Bildirim var”

“Canlı konum güncellendi”

Yani recv aslında server’ın sana push ettiği veriler.
 */
// WebSocket bağlantısı için gerekli paketler
import 'dart:async'; // Timer ve StreamSubscription için
import 'package:flutter/material.dart'; // Flutter widget'ları için
import 'package:web_socket_channel/web_socket_channel.dart'; // WebSocket bağlantısı için

// StatefulWidget: Durumu olan bir widget (bağlantı durumu, mesajlar, loglar gibi)
// Bu widget WebSocket bağlantısını yönetir ve UI'yi gösterir
class ManagedWsClientPage extends StatefulWidget {
  const ManagedWsClientPage({super.key});

  // State sınıfını oluşturur (asıl mantık orada)
  @override
  State<ManagedWsClientPage> createState() => _ManagedWsClientPageState();
}

// State sınıfı: WebSocket bağlantısının tüm mantığı burada
class _ManagedWsClientPageState extends State<ManagedWsClientPage> {
  // WebSocket server'ın URL'i (wss = güvenli WebSocket, ws = güvenli olmayan)
  // Echo server: Gönderdiğin mesajı aynen geri yollar (test için)
  final Uri _url = Uri.parse('wss://echo.websocket.org');

  // WebSocket kanalı: Server ile iletişim kurduğun ana nesne
  // Bu kanal üzerinden mesaj gönderir ve alırsın
  WebSocketChannel? _channel;

  // Stream aboneliği: Server'dan gelen mesajları dinlemek için
  // Stream = sürekli akan veri (server'dan gelen mesajlar)
  StreamSubscription? _sub;

  // Manuel kapatıldı mı? (kullanıcı disconnect butonuna bastı mı?)
  // Eğer manuel kapatıldıysa otomatik yeniden bağlanma yapılmaz
  bool _manuallyClosed = false;

  // Yeniden bağlanma deneme sayısı (exponential backoff için)
  int _retry = 0;

  // Yeniden bağlanma zamanlayıcısı (Timer ile belirli süre sonra tekrar dener)
  Timer? _reconnectTimer;

  // Bağlantı durumu metni (connecting, connected, disconnected, error vb.)
  String _statusText = 'idle';

  // Log listesi: Gönderilen/alınan mesajlar ve durum değişiklikleri
  final List<String> _logs = [];

  // TextField kontrolcüsü: Kullanıcının yazdığı mesajı tutar
  final TextEditingController _ctrl = TextEditingController();

  // Bağlantı durumu kontrolü: Sadece "connected" durumunda true döner
  // Bu sayede Send butonu sadece bağlıyken aktif olur
  bool get _isConnected => _statusText == 'connected';

  // Widget ilk oluşturulduğunda çalışır (sayfa açıldığında)
  @override
  void initState() {
    super.initState();
    // Sayfa açılır açılmaz otomatik bağlan
    connect();
  }

  // Log kaydetme fonksiyonu: Her olayı (mesaj gönderme/alma, durum değişikliği) loglar
  // updateState: UI'yi güncellemek için setState çağırılsın mı?
  void _log(String line, {bool updateState = true}) {
    // Widget hala ekranda mı? (dispose edilmişse setState yapma, hata verir)
    if (!mounted) return;

    // Zaman damgası ile log satırı oluştur
    final logLine = '${DateTime.now().toIso8601String()}  $line';

    // Log'u listenin başına ekle (en yeni üstte görünsün)
    _logs.insert(0, logLine);

    // Log listesini sınırla (performans için - çok fazla log olursa uygulama yavaşlar)
    if (_logs.length > 100) {
      _logs.removeRange(100, _logs.length);
    }

    // UI'yi güncelle (log listesi ekranda görünsün)
    if (updateState && mounted) {
      setState(() {});
    }
  }

  // Durum değiştirme fonksiyonu: Bağlantı durumunu günceller ve loglar
  void _setStatus(String s) {
    // Widget hala ekranda mı?
    if (!mounted) return;

    // Durum metnini güncelle
    _statusText = s;

    // Durum değişikliğini logla (updateState: true = UI'yi güncelle)
    _log('[status] $s', updateState: true);
  }

  // WebSocket bağlantısı kurma fonksiyonu
  void connect() {
    // Manuel kapatılmadı olarak işaretle (otomatik yeniden bağlanma için)
    _manuallyClosed = false;

    // Varsa önceki yeniden bağlanma zamanlayıcısını iptal et
    _reconnectTimer?.cancel();

    // Önce varsa eski bağlantıyı temizle (çift dinleme olmasın - memory leak önleme)
    // Eğer eski bağlantı varsa, onu kapatmadan yeni bağlantı açarsan hata olur
    _sub?.cancel(); // Eski stream dinlemesini durdur
    _sub = null; // Referansı temizle
    _channel?.sink.close(); // Eski kanalı kapat
    _channel = null; // Referansı temizle

    // Durumu "connecting" olarak güncelle
    _setStatus('connecting');

    try {
      // WebSocket bağlantısı kurma (handshake yapıyor)
      // Bu satır server'a bağlanma isteği gönderir
      // Server kabul ederse bağlantı kurulur, artık iki taraf da mesaj gönderebilir
      // Bu bağlantı kurulduktan sonra send/recv başlıyor
      _channel = WebSocketChannel.connect(_url);

      // Server'dan gelen mesajları dinle (stream = sürekli akan veri)
      // listen() = "bu stream'i dinle, her yeni veri geldiğinde bana haber ver"
      _sub = _channel!.stream.listen(
        // Server'dan veri geldiğinde çalışır (data = gelen mesaj)
        (data) {
          // İlk veri geldiğinde bağlantının gerçekten çalıştığını anlarız
          // Çünkü WebSocketChannel.connect() bağlantıyı hemen kurmaz, async çalışır
          if (_statusText != 'connected') {
            _retry = 0; // Bağlantı başarılı, retry sayacını sıfırla
            if (mounted) {
              setState(() {
                _statusText = 'connected'; // Durumu "connected" yap
              });
              _log('[status] connected'); // Logla
            }
          }
          // Gelen mesajı logla (recv = receive = alınan mesaj)
          _log('[recv] ${data.toString()}');
        },
        // Hata olduğunda çalışır (bağlantı hatası, network hatası vb.)
        onError: (e) {
          _setStatus('error: $e'); // Hata durumunu logla
          _scheduleReconnect(); // Otomatik yeniden bağlanmayı planla
        },
        // Bağlantı kapandığında çalışır (server kapattı, network kesildi vb.)
        onDone: () {
          _setStatus('disconnected'); // Bağlantı kesildi
          _scheduleReconnect(); // Otomatik yeniden bağlanmayı planla
        },
        // Hata olduğunda stream'i otomatik iptal et
        cancelOnError: true,
      );
    } catch (e) {
      // Bağlantı kurulurken exception oluşursa (örnek: URL yanlış, network yok)
      _setStatus('connect exception: $e');
      _scheduleReconnect(); // Otomatik yeniden bağlanmayı planla
    }
  }

  // Mesaj gönderme fonksiyonu: TextField'daki metni server'a gönderir
  void send() {
    // TextField'dan metni al ve başındaki/sonundaki boşlukları temizle
    final text = _ctrl.text.trim();

    // Boş mesaj gönderme
    if (text.isEmpty) return;

    // Bağlantı yoksa mesaj gönderemezsin
    if (_channel == null) {
      _log('[sent] (failed) not connected');
      return;
    }

    // WebSocket kanalı üzerinden mesajı gönder
    // sink = "gönderme ucu", add() = mesajı ekle/gönder
    _channel!.sink.add(text);

    // Gönderilen mesajı logla (sent = gönderilen mesaj)
    _log('[sent] $text');

    // TextField'ı temizle (mesaj gönderildi, artık boş olsun)
    _ctrl.clear();
  }

  // Bağlantıyı kapatma fonksiyonu: WebSocket bağlantısını kapatır
  void close() {
    // Manuel kapatıldı olarak işaretle (otomatik yeniden bağlanma yapılmasın)
    _manuallyClosed = true;

    // Yeniden bağlanma zamanlayıcısını iptal et
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Stream dinlemesini durdur (server'dan mesaj gelmesin)
    _sub?.cancel();
    _sub = null;

    // WebSocket kanalını kapat (server'a "bağlantıyı kapatıyorum" sinyali gönderir)
    _channel?.sink.close();
    _channel = null;

    // Durumu "closed" olarak güncelle
    _setStatus('closed');
  }

  // Otomatik yeniden bağlanma planlama fonksiyonu
  // Bağlantı kesildiğinde veya hata olduğunda otomatik olarak tekrar bağlanmayı dener
  void _scheduleReconnect() {
    // Eğer kullanıcı manuel olarak kapattıysa, otomatik yeniden bağlanma yapma
    if (_manuallyClosed) return;

    // Varsa önceki zamanlayıcıyı iptal et (çift zamanlayıcı olmasın)
    _reconnectTimer?.cancel();

    // Deneme sayısını artır
    _retry++;

    // Exponential backoff: Her denemede bekleme süresini artır
    // 1. deneme: 1 saniye bekle
    // 2. deneme: 2 saniye bekle
    // 3. deneme: 4 saniye bekle
    // 4. deneme: 8 saniye bekle
    // 5+ deneme: 10 saniye bekle (maksimum)
    // Neden? Server'a çok sık istek atmamak için (server'ı yormamak)
    final seconds = _retry == 1
        ? 1
        : _retry == 2
        ? 2
        : _retry == 3
        ? 4
        : _retry == 4
        ? 8
        : 10;

    // Durumu güncelle: "X saniye sonra yeniden bağlanacak"
    _setStatus('reconnecting in ${seconds}s');

    // Belirli süre sonra connect() fonksiyonunu çağır
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      // Eğer bu arada kullanıcı manuel olarak kapattıysa, bağlanma
      if (_manuallyClosed) return;
      // Tekrar bağlanmayı dene
      connect();
    });
  }

  // Widget ekrandan kaldırıldığında çalışır (sayfa kapatıldığında, geri tuşuna basıldığında)
  // Burada tüm kaynakları temizle (memory leak önleme)
  @override
  void dispose() {
    // Bağlantıyı kapat (WebSocket bağlantısını kapat, stream'i durdur)
    close();

    // TextField kontrolcüsünü temizle (memory leak önleme)
    _ctrl.dispose();

    // Parent dispose'u çağır
    super.dispose();
  }

  // UI oluşturma fonksiyonu: Ekranda görünen her şey burada
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Üst bar (AppBar)
      appBar: AppBar(
        title: const Text('WebSocket Echo Demo'),
        // Sağ üstteki butonlar
        actions: [
          // Bağlan butonu: connect() fonksiyonunu çağırır
          IconButton(
            onPressed: connect,
            tooltip: 'Connect',
            icon: const Icon(Icons.link),
          ),
          // Bağlantıyı kes butonu: close() fonksiyonunu çağırır
          IconButton(
            onPressed: close,
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
          ),
        ],
      ),
      // Ana içerik
      body: SafeArea(
        child: Column(
          children: [
            // Durum göstergesi: Bağlantı durumunu gösterir
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Bağlantı durumu metni (connecting, connected, disconnected vb.)
                  Expanded(child: Text('Status: $_statusText')),
                  const SizedBox(width: 8),
                  // Kanal durumu (on/off)
                  Text(_isConnected ? 'channel: on' : 'channel: off'),
                ],
              ),
            ),

            // Mesaj gönderme kutusu
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  // TextField: Kullanıcının mesaj yazdığı yer
                  Expanded(
                    child: TextField(
                      controller:
                          _ctrl, // TextField kontrolcüsü (yazılan metni tutar)
                      enabled: true, // Her zaman aktif (yazılabilir)
                      // Enter'a basıldığında (sadece bağlıysa gönder)
                      onSubmitted: (_) {
                        if (_isConnected) {
                          send(); // Mesaj gönder
                        }
                      },
                      decoration: InputDecoration(
                        // Bağlantı durumuna göre farklı hint text
                        hintText: _isConnected
                            ? 'Mesaj yaz (echo geri döner)'
                            : 'Mesaj yaz (bağlantı bekleniyor)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Send butonu: Mesaj gönderme butonu
                  ElevatedButton(
                    // Sadece bağlıyken aktif (null = disabled)
                    onPressed: _isConnected ? send : null,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Log listesi: Gönderilen/alınan mesajlar ve durum değişiklikleri
            const Divider(height: 1),
            Expanded(
              // Log yoksa "Log yok" mesajı göster
              child: _logs.isEmpty
                  ? const Center(child: Text('Log yok'))
                  : // Log varsa ListView ile göster
                    ListView.builder(
                      itemCount: _logs.length, // Toplam log sayısı
                      // Her log satırı için widget oluştur
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        // Log metnini göster
                        child: Text(_logs[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
