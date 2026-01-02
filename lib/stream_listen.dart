/*
Firebase Push: App kapalıyken bile çalışır OS’e “kullanıcıya haber ver” der Kullanıcı bildirime tıklar → app açılır
Ama şunu yapmaz: App açıkken UI’yi otomatik güncellemez Anlık veri akışı sağlamaz Örnek: “Yeni sipariş var” bildirimi geldi
Ama liste yenilenmez, sen manuel fetch yaparsın. WebSocket ise  Buradaki “bildirim” şu anlama geliyor: Server’da bir
olay oldu → uygulama bunu anında öğrendi Yani: OS notification değil Push değil Bu tamamen canlı veri haberi.
Server’da yeni sipariş olur Server → hemen app’e mesaj yollar Stream’e yeni event düşer State değişir
UI kendiliğinden güncellenir❗ Refresh yok❗ Restart yok❗ Tekrar fetch yok WebSocket: Bu verileri tek tek gönderir
Stream: Flutter’da bu akışı düzgün şekilde dinlememizi sağlar WebSocket bir iletişim protokolü / bağlantı türü:
“server ile sürekli açık bir hat kur, iki taraf da istediği an mesaj yollasın” demek. StreamBuilder nedir?
StreamBuilder bir Widget’tır. Stream’i dinler ve her yeni event geldiğinde UI’yi otomatik rebuild eder.
Yani:Stream = veri hattı StreamBuilder = bu hattı UI’ye bağlayan widget StreamBuilder, “ben bu stream’e göre ekranda bir
şey çizmek istiyorum” dediğinde pratik olur Firebase’in arkasında server var, doğru. Ama o server: Senin “custom WebSocket
endpoint”in gibi davranmaz endpointe bağlanıp, istediğin protokolü konuştuğun bir yer değildir bu nedenle fırebase ıle
websocket yınetımı yapamazsın Flutter’da bu genelde şu iki API ile olur: Firestore: snapshots() Realtime Database: onValue,
onChildAdded, onChildChanged vb. Bunlar Dart tarafında Stream üretir.İkisi de real-time olabilir Realtime Database “anlık
akış” hissini daha belirgin yaşatır Firestore da real-time ama doğru API’yi (snapshots) kullanman şart


Yol-2: Servis/State tarafında listen() ile (state management ile daha “temiz”)
UI’dan bağımsız dinlersin, state’i güncellersin
Stream’den event gelince senin state’in güncellenir
State güncellenince Flutter o widget’ı yeniden build eder

late final StreamSubscription sub;

@override
void initState() {
  super.initState();
  sub = FirebaseFirestore.instance
      .collection('orders')
      .snapshots()
      .listen((snapshot) {
        // state güncelle
      });
}

@override
void dispose() {
  sub.cancel();
  super.dispose();
}
 */

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

//Yol-1: UI’da StreamBuilder ile (en görsel, en hızlı)
//Stream’den gelen her event’te widget otomatik yenilenir.
class FirestoreStreamListen extends StatefulWidget {
  FirestoreStreamListen({Key? key}) : super(key: key);

  @override
  _FirestoreStreamListenState createState() => _FirestoreStreamListenState();
}

class _FirestoreStreamListenState extends State<FirestoreStreamListen> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      //canlı olarak dinler veri akışını
      //Yani senin kodunda “stream dinleme”yi yapan şey snapshots().
      //Bu stream’e event gelmesini tetikleyen şeyler orders koleksiyonunda bu sorgunun sonucunu değiştiren her şeydir.
      stream: FirebaseFirestore.instance.collection('orders').snapshots(),
      //Stream’den event gelince StreamBuilder’ın builder’ı tekrar çalışır streambuilder ile dinleyince direkt ui guncellenır
      //listen() ile dinleme state management ile yapılır gelen veriyi state management a yazarsın
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('Hata');
        if (!snapshot.hasData) return const Text('Yükleniyor');
        final docs = snapshot.data!.docs;
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) =>
              Text(docs[i]['orderName']?.toString() ?? ''),
        );
      },
    );
  }
}

//realtime database stream listen onvalue
class RtdbStreamListen extends StatelessWidget {
  RtdbStreamListen({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      //orders altında herhangi bir değişiklik olursa (ekleme/güncelleme/silme), sana orders’ın o anki komple halini (snapshot) gönderir.
      //Dezavantaj: orders çok büyürse, her küçük değişimde “tam ağacı” tekrar alırsın (fazladan data/iş).
      stream: FirebaseDatabase.instance
          .ref('orders')
          .onValue, // RTDB onValue = canlı dinleme
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('Hata');
        if (!snapshot.hasData) return const Text('Yükleniyor');

        final value = snapshot.data!.snapshot.value;

        // orders altında veri yoksa null gelebilir
        if (value == null) return const Text('Veri yok');

        // RTDB genelde Map olarak döner, ama bazen String de olabilir
        if (value is! Map) {
          // Eğer value bir String ise, direkt göster
          if (value is String) {
            return Text(value);
          }
          // Diğer durumlar için
          return Text(value.toString());
        }

        final map = Map<Object?, Object?>.from(value);

        final items = map.entries.toList();

        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            try {
              final itemValue = items[i].value;

              // Eğer value bir Map ise
              if (itemValue is Map) {
                final item = Map<Object?, Object?>.from(itemValue);
                return Text(item['orderName']?.toString() ?? '');
              }

              // Eğer value bir String ise
              if (itemValue is String) {
                return Text(itemValue);
              }

              // Diğer durumlar için
              return Text(itemValue?.toString() ?? '');
            } catch (e) {
              // Hata durumunda boş text döndür
              return const Text('');
            }
          },
        );
      },
    );
  }
}

//onChildAdded ile: Sana sadece eklenen child gelir. Yani event’teki snapshot: snapshot.key = "orderId" snapshot.value = 1
//Tüm orders ağacı gelmez. (onValue’daki gibi değil)
class RtdbStreamListenOnChildAdded extends StatelessWidget {
  RtdbStreamListenOnChildAdded({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      //orders altında yeni bir child eklendiğinde (ekleme), sana orders'ın o anki komple halini (snapshot) gönderir.
      stream: FirebaseDatabase.instance
          .ref('orders')
          .onChildAdded, // RTDB onChildAdded = canlı dinleme
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Text('Hata');
        if (!snapshot.hasData) return const Text('Yükleniyor');
        
        //Event’in değerini alıyorsun Bu value, eklenen child’ın value’su.
        final value = snapshot.data!.snapshot.value;

        // orders altında veri yoksa null gelebilir
        if (value == null) return const Text('Veri yok');

        // RTDB genelde Map olarak döner, ama bazen String de olabilir
        if (value is! Map) {
          // Eğer value bir String ise, direkt göster
          if (value is String) {
            return Text(value);
          }
          // Diğer durumlar için
          return Text(value.toString());
        }

        final map = Map<Object?, Object?>.from(value);

        final items = map.entries.toList();

        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            try {
              final itemValue = items[i].value;

              // Eğer value bir Map ise
              if (itemValue is Map) {
                final item = Map<Object?, Object?>.from(itemValue);
                return Text(item['orderName']?.toString() ?? '');
              }

              // Eğer value bir String ise
              if (itemValue is String) {
                return Text(itemValue);
              }

              // Diğer durumlar için
              return Text(itemValue?.toString() ?? '');
            } catch (e) {
              // Hata durumunda boş text döndür
              return const Text('');
            }
          },
        );
      },
    );
  }
}
