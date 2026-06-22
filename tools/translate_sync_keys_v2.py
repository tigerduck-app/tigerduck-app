#!/usr/bin/env python3
"""Translate 17 Cloud Sync keys for all locales that still show English."""
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = os.path.join(SCRIPT_DIR, "..", "localization", "source")

# fmt: off
TRANSLATIONS = {
    "ar": {
        "shared": {
            "onboarding_sync_not_shared_password": "لا يتم رفع كلمة المرور أبدًا",
            "onboarding_sync_shared_assignments": "بيانات الواجبات",
            "onboarding_sync_shared_courses": "بيانات المقررات",
            "onboarding_sync_shared_moodle_token": "رمز Moodle (مشفّر)",
            "onboarding_sync_shared_student_id": "رقم الطالب",
            "sync_conflict_message": "بعض العناصر تختلف بين هذا الجهاز والخادم:",
            "sync_conflict_status_completed": "مكتمل",
            "sync_conflict_status_ignored": "متجاهل",
            "sync_conflict_status_none": "لا شيء",
            "sync_conflict_title": "تعارض في المزامنة",
            "sync_conflict_use_local": "استخدام المحلي",
            "sync_conflict_use_server": "استخدام الخادم",
            "sync_fdroid_unavailable_body": "تتطلب المزامنة السحابية خدمات Google Play وغير متوفرة في إصدار F-Droid.",
            "sync_fdroid_unavailable_title": "غير متوفر على F-Droid",
            "settings_sync_brief_description": "تتيح لك المزامنة السحابية مزامنة معلوماتك المختارة عبر جميع أجهزتك التي تم تفعيل المزامنة السحابية عليها. المعلومات غير المفعّلة للمزامنة تبقى على هذا الجهاز فقط.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "المزامنة بين الأجهزة معطّلة. تعتمد أجهزة Apple على خادم TigerDuck لتلقي الإشعارات. انقر لمزيد من المعلومات.",
            "settings_sync_brief_description_ios": "تتيح لك المزامنة السحابية تلقي الإشعارات الفورية ومزامنة معلوماتك المختارة عبر جميع أجهزتك. المعلومات غير المفعّلة للمزامنة تُرسل إلى الخادم لاستخدام الإشعارات.",
        },
    },
    "bg": {
        "shared": {
            "onboarding_sync_not_shared_password": "Паролата никога не се качва",
            "onboarding_sync_shared_assignments": "Данни за задачите",
            "onboarding_sync_shared_courses": "Данни за курсовете",
            "onboarding_sync_shared_moodle_token": "Moodle токен (криптиран)",
            "onboarding_sync_shared_student_id": "Студентски номер",
            "sync_conflict_message": "Някои елементи се различават между това устройство и сървъра:",
            "sync_conflict_status_completed": "Завършено",
            "sync_conflict_status_ignored": "Игнорирано",
            "sync_conflict_status_none": "Няма",
            "sync_conflict_title": "Конфликт при синхронизация",
            "sync_conflict_use_local": "Локално",
            "sync_conflict_use_server": "От сървъра",
            "sync_fdroid_unavailable_body": "Облачната синхронизация изисква Google Play услуги и не е налична в F-Droid версията.",
            "sync_fdroid_unavailable_title": "Не е налично за F-Droid",
            "settings_sync_brief_description": "Облачната синхронизация ви позволява да синхронизирате избраната информация между всички устройства с включена облачна синхронизация. Информацията, която не е включена, остава само на това устройство.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Синхронизацията между устройства е изключена. Apple устройствата разчитат на сървъра на TigerDuck за получаване на известия. Натиснете за повече информация.",
            "settings_sync_brief_description_ios": "Облачната синхронизация ви позволява да получавате push известия и да синхронизирате избраната информация между устройствата. Информацията, която не е включена за синхронизация, все пак се изпраща на сървъра за push известия.",
        },
    },
    "bn": {
        "shared": {
            "onboarding_sync_not_shared_password": "পাসওয়ার্ড কখনো আপলোড করা হয় না",
            "onboarding_sync_shared_assignments": "অ্যাসাইনমেন্ট ডেটা",
            "onboarding_sync_shared_courses": "কোর্স ডেটা",
            "onboarding_sync_shared_moodle_token": "Moodle টোকেন (এনক্রিপ্টেড)",
            "onboarding_sync_shared_student_id": "ছাত্র আইডি",
            "sync_conflict_message": "এই ডিভাইস এবং সার্ভারের মধ্যে কিছু আইটেম ভিন্ন:",
            "sync_conflict_status_completed": "সম্পন্ন",
            "sync_conflict_status_ignored": "উপেক্ষিত",
            "sync_conflict_status_none": "কিছু নেই",
            "sync_conflict_title": "সিঙ্ক দ্বন্দ্ব",
            "sync_conflict_use_local": "স্থানীয় ব্যবহার করুন",
            "sync_conflict_use_server": "সার্ভার ব্যবহার করুন",
            "sync_fdroid_unavailable_body": "ক্লাউড সিঙ্কের জন্য Google Play পরিষেবা প্রয়োজন এবং F-Droid বিল্ডে উপলব্ধ নয়।",
            "sync_fdroid_unavailable_title": "F-Droid-এ উপলব্ধ নয়",
            "settings_sync_brief_description": "ক্লাউড সিঙ্ক আপনাকে আপনার সমস্ত ডিভাইসে তথ্য সিঙ্ক করতে দেয়। সিঙ্কের জন্য সক্ষম নয় এমন তথ্য শুধুমাত্র এই ডিভাইসে থাকে।",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "ক্রস-ডিভাইস সিঙ্ক বন্ধ। Apple ডিভাইসগুলি বিজ্ঞপ্তি পেতে TigerDuck ব্যাকএন্ডের উপর নির্ভর করে। আরও জানতে ট্যাপ করুন।",
            "settings_sync_brief_description_ios": "ক্লাউড সিঙ্ক আপনাকে পুশ নোটিফিকেশন পেতে এবং তথ্য সিঙ্ক করতে দেয়। সিঙ্কের জন্য সক্ষম নয় এমন তথ্যও পুশ নোটিফিকেশনের জন্য সার্ভারে পাঠানো হয়।",
        },
    },
    "ca": {
        "shared": {
            "onboarding_sync_not_shared_password": "La contrasenya mai es puja",
            "onboarding_sync_shared_assignments": "Dades dels treballs",
            "onboarding_sync_shared_courses": "Dades dels cursos",
            "onboarding_sync_shared_moodle_token": "Token de Moodle (xifrat)",
            "onboarding_sync_shared_student_id": "ID d'estudiant",
            "sync_conflict_message": "Alguns elements difereixen entre aquest dispositiu i el servidor:",
            "sync_conflict_status_completed": "Completat",
            "sync_conflict_status_ignored": "Ignorat",
            "sync_conflict_status_none": "Cap",
            "sync_conflict_title": "Conflicte de sincronització",
            "sync_conflict_use_local": "Usar local",
            "sync_conflict_use_server": "Usar servidor",
            "sync_fdroid_unavailable_body": "La sincronització al núvol requereix els serveis de Google Play i no està disponible a la versió F-Droid.",
            "sync_fdroid_unavailable_title": "No disponible a F-Droid",
            "settings_sync_brief_description": "La sincronització al núvol permet sincronitzar la informació seleccionada entre tots els dispositius amb la sincronització activada. La informació no activada es queda només en aquest dispositiu.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "La sincronització entre dispositius està desactivada. Els dispositius Apple necessiten el servidor TigerDuck per rebre notificacions. Toca per a més informació.",
            "settings_sync_brief_description_ios": "La sincronització al núvol permet rebre notificacions push i sincronitzar la informació entre dispositius. La informació no activada s'envia igualment al servidor per a les notificacions push.",
        },
    },
    "cs": {
        "shared": {
            "onboarding_sync_not_shared_password": "Heslo se nikdy nenahrává",
            "onboarding_sync_shared_assignments": "Data úkolů",
            "onboarding_sync_shared_courses": "Data kurzů",
            "onboarding_sync_shared_moodle_token": "Moodle token (šifrovaný)",
            "onboarding_sync_shared_student_id": "Studentské ID",
            "sync_conflict_message": "Některé položky se liší mezi tímto zařízením a serverem:",
            "sync_conflict_status_completed": "Dokončeno",
            "sync_conflict_status_ignored": "Ignorováno",
            "sync_conflict_status_none": "Žádný",
            "sync_conflict_title": "Konflikt synchronizace",
            "sync_conflict_use_local": "Použít místní",
            "sync_conflict_use_server": "Použít server",
            "sync_fdroid_unavailable_body": "Cloudová synchronizace vyžaduje služby Google Play a není dostupná v sestavení F-Droid.",
            "sync_fdroid_unavailable_title": "Nedostupné na F-Droid",
            "settings_sync_brief_description": "Cloudová synchronizace umožňuje synchronizovat vybrané informace mezi všemi zařízeními se zapnutou synchronizací. Informace bez synchronizace zůstávají pouze na tomto zařízení.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Synchronizace mezi zařízeními je vypnutá. Zařízení Apple potřebují server TigerDuck pro příjem oznámení. Klepněte pro více informací.",
            "settings_sync_brief_description_ios": "Cloudová synchronizace umožňuje přijímat push oznámení a synchronizovat vybrané informace. Informace bez synchronizace se i tak odesílají na server pro push oznámení.",
        },
    },
    "da": {
        "shared": {
            "onboarding_sync_not_shared_password": "Adgangskoden uploades aldrig",
            "onboarding_sync_shared_assignments": "Opgavedata",
            "onboarding_sync_shared_courses": "Kursusdata",
            "onboarding_sync_shared_moodle_token": "Moodle-token (krypteret)",
            "onboarding_sync_shared_student_id": "Studie-ID",
            "sync_conflict_message": "Nogle elementer er forskellige mellem denne enhed og serveren:",
            "sync_conflict_status_completed": "Fuldført",
            "sync_conflict_status_ignored": "Ignoreret",
            "sync_conflict_status_none": "Ingen",
            "sync_conflict_title": "Synkroniseringskonflikt",
            "sync_conflict_use_local": "Brug lokal",
            "sync_conflict_use_server": "Brug server",
            "sync_fdroid_unavailable_body": "Cloud Sync kræver Google Play-tjenester og er ikke tilgængelig i F-Droid-versionen.",
            "sync_fdroid_unavailable_title": "Ikke tilgængelig på F-Droid",
            "settings_sync_brief_description": "Cloud Sync lader dig synkronisere dine valgte oplysninger på tværs af alle enheder med Cloud Sync aktiveret. Oplysninger uden synkronisering forbliver kun på denne enhed.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Synkronisering på tværs af enheder er slået fra. Apple-enheder er afhængige af TigerDuck-serveren for at modtage notifikationer. Tryk for mere info.",
            "settings_sync_brief_description_ios": "Cloud Sync lader dig modtage push-notifikationer og synkronisere oplysninger. Oplysninger uden synkronisering sendes stadig til serveren til push-notifikationer.",
        },
    },
    "de": {
        "shared": {
            "onboarding_sync_not_shared_password": "Das Passwort wird niemals hochgeladen",
            "onboarding_sync_shared_assignments": "Aufgabendaten",
            "onboarding_sync_shared_courses": "Kursdaten",
            "onboarding_sync_shared_moodle_token": "Moodle-Token (verschlüsselt)",
            "onboarding_sync_shared_student_id": "Matrikelnummer",
            "sync_conflict_message": "Einige Einträge unterscheiden sich zwischen diesem Gerät und dem Server:",
            "sync_conflict_status_completed": "Erledigt",
            "sync_conflict_status_ignored": "Ignoriert",
            "sync_conflict_status_none": "Keine",
            "sync_conflict_title": "Synchronisierungskonflikt",
            "sync_conflict_use_local": "Lokal verwenden",
            "sync_conflict_use_server": "Server verwenden",
            "sync_fdroid_unavailable_body": "Cloud Sync erfordert Google Play-Dienste und ist im F-Droid-Build nicht verfügbar.",
            "sync_fdroid_unavailable_title": "Auf F-Droid nicht verfügbar",
            "settings_sync_brief_description": "Mit Cloud Sync kannst du ausgewählte Daten auf allen Geräten synchronisieren, auf denen Cloud Sync aktiviert ist. Nicht aktivierte Daten bleiben nur auf diesem Gerät.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Geräteübergreifende Synchronisierung ist deaktiviert. Apple-Geräte benötigen den TigerDuck-Server für Benachrichtigungen. Tippe für mehr Infos.",
            "settings_sync_brief_description_ios": "Cloud Sync ermöglicht dir Push-Benachrichtigungen zu empfangen und Daten zwischen Geräten zu synchronisieren. Nicht synchronisierte Daten werden trotzdem für Push-Benachrichtigungen an den Server gesendet.",
        },
    },
    "el": {
        "shared": {
            "onboarding_sync_not_shared_password": "Ο κωδικός δεν μεταφορτώνεται ποτέ",
            "onboarding_sync_shared_assignments": "Δεδομένα εργασιών",
            "onboarding_sync_shared_courses": "Δεδομένα μαθημάτων",
            "onboarding_sync_shared_moodle_token": "Token Moodle (κρυπτογραφημένο)",
            "onboarding_sync_shared_student_id": "Αριθμός φοιτητή",
            "sync_conflict_message": "Ορισμένα στοιχεία διαφέρουν μεταξύ αυτής της συσκευής και του διακομιστή:",
            "sync_conflict_status_completed": "Ολοκληρώθηκε",
            "sync_conflict_status_ignored": "Αγνοήθηκε",
            "sync_conflict_status_none": "Κανένα",
            "sync_conflict_title": "Σύγκρουση συγχρονισμού",
            "sync_conflict_use_local": "Τοπικά",
            "sync_conflict_use_server": "Από διακομιστή",
            "sync_fdroid_unavailable_body": "Ο συγχρονισμός cloud απαιτεί υπηρεσίες Google Play και δεν είναι διαθέσιμος στην έκδοση F-Droid.",
            "sync_fdroid_unavailable_title": "Μη διαθέσιμο στο F-Droid",
            "settings_sync_brief_description": "Ο συγχρονισμός cloud σας επιτρέπει να συγχρονίζετε τις επιλεγμένες πληροφορίες σε όλες τις συσκευές. Οι πληροφορίες χωρίς συγχρονισμό παραμένουν μόνο σε αυτή τη συσκευή.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Ο συγχρονισμός μεταξύ συσκευών είναι απενεργοποιημένος. Οι συσκευές Apple βασίζονται στον διακομιστή TigerDuck για ειδοποιήσεις. Πατήστε για περισσότερες πληροφορίες.",
            "settings_sync_brief_description_ios": "Ο συγχρονισμός cloud σας επιτρέπει να λαμβάνετε push ειδοποιήσεις και να συγχρονίζετε πληροφορίες. Οι πληροφορίες χωρίς συγχρονισμό αποστέλλονται στον διακομιστή για push ειδοποιήσεις.",
        },
    },
    "en-GB": {
        "shared": {
            "onboarding_sync_not_shared_password": "Password is never uploaded",
            "onboarding_sync_shared_assignments": "Assignment data",
            "onboarding_sync_shared_courses": "Course data",
            "onboarding_sync_shared_moodle_token": "Moodle token (encrypted)",
            "onboarding_sync_shared_student_id": "Student ID",
            "sync_conflict_message": "Some items differ between this device and the server:",
            "sync_conflict_status_completed": "Completed",
            "sync_conflict_status_ignored": "Ignored",
            "sync_conflict_status_none": "None",
            "sync_conflict_title": "Sync Conflict",
            "sync_conflict_use_local": "Use Local",
            "sync_conflict_use_server": "Use Server",
            "sync_fdroid_unavailable_body": "Cloud Sync requires Google Play Services and is not available in the F-Droid build.",
            "sync_fdroid_unavailable_title": "Not available on F-Droid",
            "settings_sync_brief_description": "Cloud Sync lets you sync your chosen information across all your devices that have Cloud Sync turned on. Information not enabled for Cloud Sync stays on this device only.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Cross-device sync is off. Apple devices rely on TigerDuck backend to receive notifications. Tap for more info.",
            "settings_sync_brief_description_ios": "Cloud Sync lets you receive push notifications and sync your chosen information across all your devices that have Cloud Sync turned on. Information not enabled for sync is still sent to the server for push notification use.",
        },
    },
    "es": {
        "shared": {
            "onboarding_sync_not_shared_password": "La contraseña nunca se sube",
            "onboarding_sync_shared_assignments": "Datos de tareas",
            "onboarding_sync_shared_courses": "Datos de cursos",
            "onboarding_sync_shared_moodle_token": "Token de Moodle (cifrado)",
            "onboarding_sync_shared_student_id": "ID de estudiante",
            "sync_conflict_message": "Algunos elementos difieren entre este dispositivo y el servidor:",
            "sync_conflict_status_completed": "Completado",
            "sync_conflict_status_ignored": "Ignorado",
            "sync_conflict_status_none": "Ninguno",
            "sync_conflict_title": "Conflicto de sincronización",
            "sync_conflict_use_local": "Usar local",
            "sync_conflict_use_server": "Usar servidor",
            "sync_fdroid_unavailable_body": "La sincronización en la nube requiere Google Play Services y no está disponible en la versión F-Droid.",
            "sync_fdroid_unavailable_title": "No disponible en F-Droid",
            "settings_sync_brief_description": "La sincronización en la nube te permite sincronizar la información seleccionada en todos tus dispositivos con sincronización activada. La información no activada permanece solo en este dispositivo.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "La sincronización entre dispositivos está desactivada. Los dispositivos Apple dependen del servidor TigerDuck para recibir notificaciones. Toca para más información.",
            "settings_sync_brief_description_ios": "La sincronización en la nube te permite recibir notificaciones push y sincronizar información entre dispositivos. La información no activada se envía al servidor para notificaciones push.",
        },
    },
    "et": {
        "shared": {
            "onboarding_sync_not_shared_password": "Parooli ei laadita kunagi üles",
            "onboarding_sync_shared_assignments": "Ülesannete andmed",
            "onboarding_sync_shared_courses": "Kursuste andmed",
            "onboarding_sync_shared_moodle_token": "Moodle'i token (krüpteeritud)",
            "onboarding_sync_shared_student_id": "Tudengi ID",
            "sync_conflict_message": "Mõned üksused erinevad selle seadme ja serveri vahel:",
            "sync_conflict_status_completed": "Lõpetatud",
            "sync_conflict_status_ignored": "Ignoreeritud",
            "sync_conflict_status_none": "Puudub",
            "sync_conflict_title": "Sünkroonimise konflikt",
            "sync_conflict_use_local": "Kasuta kohalikku",
            "sync_conflict_use_server": "Kasuta serverit",
            "sync_fdroid_unavailable_body": "Pilve sünkroonimine nõuab Google Play teenuseid ja pole F-Droidi versioonis saadaval.",
            "sync_fdroid_unavailable_title": "Pole F-Droidis saadaval",
            "settings_sync_brief_description": "Pilve sünkroonimine võimaldab sünkroonida valitud teavet kõigi seadmete vahel. Sünkroonimata teave jääb ainult sellesse seadmesse.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Seadmete vaheline sünkroonimine on välja lülitatud. Apple'i seadmed vajavad TigerDucki serverit teavituste saamiseks. Puudutage lisateabe saamiseks.",
            "settings_sync_brief_description_ios": "Pilve sünkroonimine võimaldab saada push-teavitusi ja sünkroonida teavet seadmete vahel. Sünkroonimata teave saadetakse siiski serverisse push-teavituste jaoks.",
        },
    },
    "fa": {
        "shared": {
            "onboarding_sync_not_shared_password": "رمز عبور هرگز آپلود نمی‌شود",
            "onboarding_sync_shared_assignments": "داده‌های تکالیف",
            "onboarding_sync_shared_courses": "داده‌های دروس",
            "onboarding_sync_shared_moodle_token": "توکن Moodle (رمزگذاری شده)",
            "onboarding_sync_shared_student_id": "شماره دانشجویی",
            "sync_conflict_message": "برخی موارد بین این دستگاه و سرور متفاوت هستند:",
            "sync_conflict_status_completed": "تکمیل شده",
            "sync_conflict_status_ignored": "نادیده گرفته شده",
            "sync_conflict_status_none": "هیچ",
            "sync_conflict_title": "تداخل همگام‌سازی",
            "sync_conflict_use_local": "استفاده از محلی",
            "sync_conflict_use_server": "استفاده از سرور",
            "sync_fdroid_unavailable_body": "همگام‌سازی ابری به خدمات Google Play نیاز دارد و در نسخه F-Droid موجود نیست.",
            "sync_fdroid_unavailable_title": "در F-Droid موجود نیست",
            "settings_sync_brief_description": "همگام‌سازی ابری به شما امکان می‌دهد اطلاعات انتخابی خود را در تمام دستگاه‌ها همگام کنید. اطلاعات غیرفعال فقط در این دستگاه باقی می‌مانند.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "همگام‌سازی بین دستگاه‌ها خاموش است. دستگاه‌های Apple برای دریافت اعلان‌ها به سرور TigerDuck نیاز دارند. برای اطلاعات بیشتر ضربه بزنید.",
            "settings_sync_brief_description_ios": "همگام‌سازی ابری به شما امکان دریافت اعلان‌های فوری و همگام‌سازی اطلاعات را می‌دهد. اطلاعات غیرفعال همچنان برای اعلان‌ها به سرور ارسال می‌شوند.",
        },
    },
    "fi": {
        "shared": {
            "onboarding_sync_not_shared_password": "Salasanaa ei koskaan ladata",
            "onboarding_sync_shared_assignments": "Tehtävätiedot",
            "onboarding_sync_shared_courses": "Kurssitiedot",
            "onboarding_sync_shared_moodle_token": "Moodle-tunniste (salattu)",
            "onboarding_sync_shared_student_id": "Opiskelijanumero",
            "sync_conflict_message": "Jotkin kohteet eroavat tämän laitteen ja palvelimen välillä:",
            "sync_conflict_status_completed": "Valmis",
            "sync_conflict_status_ignored": "Ohitettu",
            "sync_conflict_status_none": "Ei mitään",
            "sync_conflict_title": "Synkronointiristiriita",
            "sync_conflict_use_local": "Käytä paikallista",
            "sync_conflict_use_server": "Käytä palvelinta",
            "sync_fdroid_unavailable_body": "Pilvisynkronointi vaatii Google Play -palvelut eikä ole käytettävissä F-Droid-versiossa.",
            "sync_fdroid_unavailable_title": "Ei saatavilla F-Droidissa",
            "settings_sync_brief_description": "Pilvisynkronointi mahdollistaa valittujen tietojen synkronoinnin kaikkien laitteiden välillä. Synkronoimattomat tiedot pysyvät vain tässä laitteessa.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Laitteiden välinen synkronointi on pois päältä. Apple-laitteet tarvitsevat TigerDuck-palvelimen ilmoitusten vastaanottamiseen. Napauta lisätietoja.",
            "settings_sync_brief_description_ios": "Pilvisynkronointi mahdollistaa push-ilmoitusten vastaanoton ja tietojen synkronoinnin. Synkronoimattomat tiedot lähetetään silti palvelimelle push-ilmoituksia varten.",
        },
    },
    "fil": {
        "shared": {
            "onboarding_sync_not_shared_password": "Hindi kailanman ina-upload ang password",
            "onboarding_sync_shared_assignments": "Data ng mga gawain",
            "onboarding_sync_shared_courses": "Data ng mga kurso",
            "onboarding_sync_shared_moodle_token": "Moodle token (naka-encrypt)",
            "onboarding_sync_shared_student_id": "Student ID",
            "sync_conflict_message": "May mga item na magkaiba sa pagitan ng device na ito at ng server:",
            "sync_conflict_status_completed": "Natapos",
            "sync_conflict_status_ignored": "Hindi pinansin",
            "sync_conflict_status_none": "Wala",
            "sync_conflict_title": "Salungatan sa Sync",
            "sync_conflict_use_local": "Gamitin ang Lokal",
            "sync_conflict_use_server": "Gamitin ang Server",
            "sync_fdroid_unavailable_body": "Ang Cloud Sync ay nangangailangan ng Google Play Services at hindi available sa F-Droid build.",
            "sync_fdroid_unavailable_title": "Hindi available sa F-Droid",
            "settings_sync_brief_description": "Pinapayagan ka ng Cloud Sync na i-sync ang iyong napiling impormasyon sa lahat ng device. Ang impormasyong hindi naka-enable ay mananatili lamang sa device na ito.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "Naka-off ang cross-device sync. Umaasa ang mga Apple device sa TigerDuck backend para sa mga notification. I-tap para sa higit pang impormasyon.",
            "settings_sync_brief_description_ios": "Pinapayagan ka ng Cloud Sync na makatanggap ng push notification at i-sync ang impormasyon. Ang hindi naka-enable na impormasyon ay ipinapadala pa rin sa server para sa push notification.",
        },
    },
    "fr": {
        "shared": {
            "onboarding_sync_not_shared_password": "Le mot de passe n'est jamais envoyé",
            "onboarding_sync_shared_assignments": "Données des devoirs",
            "onboarding_sync_shared_courses": "Données des cours",
            "onboarding_sync_shared_moodle_token": "Jeton Moodle (chiffré)",
            "onboarding_sync_shared_student_id": "Numéro étudiant",
            "sync_conflict_message": "Certains éléments diffèrent entre cet appareil et le serveur :",
            "sync_conflict_status_completed": "Terminé",
            "sync_conflict_status_ignored": "Ignoré",
            "sync_conflict_status_none": "Aucun",
            "sync_conflict_title": "Conflit de synchronisation",
            "sync_conflict_use_local": "Utiliser local",
            "sync_conflict_use_server": "Utiliser serveur",
            "sync_fdroid_unavailable_body": "La synchronisation cloud nécessite les services Google Play et n'est pas disponible dans la version F-Droid.",
            "sync_fdroid_unavailable_title": "Non disponible sur F-Droid",
            "settings_sync_brief_description": "La synchronisation cloud vous permet de synchroniser vos informations choisies sur tous vos appareils. Les informations non activées restent uniquement sur cet appareil.",
        },
        "apple": {
            "settings_sync_off_notifications_warning": "La synchronisation inter-appareils est désactivée. Les appareils Apple dépendent du serveur TigerDuck pour les notifications. Appuyez pour en savoir plus.",
            "settings_sync_brief_description_ios": "La synchronisation cloud vous permet de recevoir des notifications push et de synchroniser vos informations. Les informations non activées sont quand même envoyées au serveur pour les notifications push.",
        },
    },
    "gu": {"shared": {"onboarding_sync_not_shared_password": "પાસવર્ડ ક્યારેય અપલોડ થતો નથી", "onboarding_sync_shared_assignments": "એસાઇનમેન્ટ ડેટા", "onboarding_sync_shared_courses": "કોર્સ ડેટા", "onboarding_sync_shared_moodle_token": "Moodle ટોકન (એન્ક્રિપ્ટેડ)", "onboarding_sync_shared_student_id": "વિદ્યાર્થી ID", "sync_conflict_message": "આ ઉપકરણ અને સર્વર વચ્ચે કેટલીક વસ્તુઓ અલગ છે:", "sync_conflict_status_completed": "પૂર્ણ", "sync_conflict_status_ignored": "અવગણેલ", "sync_conflict_status_none": "કંઈ નહીં", "sync_conflict_title": "સિંક વિરોધ", "sync_conflict_use_local": "સ્થાનિક વાપરો", "sync_conflict_use_server": "સર્વર વાપરો", "sync_fdroid_unavailable_body": "ક્લાઉડ સિંક માટે Google Play સેવાઓ જરૂરી છે અને F-Droid બિલ્ડમાં ઉપલબ્ધ નથી.", "sync_fdroid_unavailable_title": "F-Droid પર ઉપલબ્ધ નથી", "settings_sync_brief_description": "ક્લાઉડ સિંક તમને તમારા બધા ઉપકરણો પર માહિતી સિંક કરવા દે છે. સિંક માટે સક્ષમ ન હોય તેવી માહિતી ફક્ત આ ઉપકરણ પર રહે છે."}, "apple": {"settings_sync_off_notifications_warning": "ક્રોસ-ડિવાઇસ સિંક બંધ છે. Apple ઉપકરણોને સૂચનાઓ માટે TigerDuck સર્વરની જરૂર છે. વધુ માહિતી માટે ટેપ કરો.", "settings_sync_brief_description_ios": "ક્લાઉડ સિંક તમને પુશ સૂચનાઓ પ્રાપ્ત કરવા અને માહિતી સિંક કરવા દે છે. સિંક માટે સક્ષમ ન હોય તેવી માહિતી પણ પુશ સૂચનાઓ માટે સર્વરને મોકલવામાં આવે છે."}},
    "he": {"shared": {"onboarding_sync_not_shared_password": "הסיסמה לעולם לא מועלית", "onboarding_sync_shared_assignments": "נתוני מטלות", "onboarding_sync_shared_courses": "נתוני קורסים", "onboarding_sync_shared_moodle_token": "טוקן Moodle (מוצפן)", "onboarding_sync_shared_student_id": "מספר סטודנט", "sync_conflict_message": "חלק מהפריטים שונים בין מכשיר זה לשרת:", "sync_conflict_status_completed": "הושלם", "sync_conflict_status_ignored": "התעלם", "sync_conflict_status_none": "אין", "sync_conflict_title": "סתירת סנכרון", "sync_conflict_use_local": "השתמש במקומי", "sync_conflict_use_server": "השתמש בשרת", "sync_fdroid_unavailable_body": "סנכרון ענן דורש שירותי Google Play ואינו זמין בגרסת F-Droid.", "sync_fdroid_unavailable_title": "לא זמין ב-F-Droid", "settings_sync_brief_description": "סנכרון ענן מאפשר לך לסנכרן מידע נבחר בין כל המכשירים שלך. מידע שלא הופעל לסנכרון נשאר במכשיר זה בלבד."}, "apple": {"settings_sync_off_notifications_warning": "סנכרון בין מכשירים כבוי. מכשירי Apple מסתמכים על שרת TigerDuck לקבלת התראות. הקש למידע נוסף.", "settings_sync_brief_description_ios": "סנכרון ענן מאפשר לך לקבל התראות push ולסנכרן מידע. מידע שלא הופעל לסנכרון עדיין נשלח לשרת להתראות push."}},
    "hi": {"shared": {"onboarding_sync_not_shared_password": "पासवर्ड कभी अपलोड नहीं किया जाता", "onboarding_sync_shared_assignments": "असाइनमेंट डेटा", "onboarding_sync_shared_courses": "कोर्स डेटा", "onboarding_sync_shared_moodle_token": "Moodle टोकन (एन्क्रिप्टेड)", "onboarding_sync_shared_student_id": "छात्र आईडी", "sync_conflict_message": "इस डिवाइस और सर्वर के बीच कुछ आइटम भिन्न हैं:", "sync_conflict_status_completed": "पूर्ण", "sync_conflict_status_ignored": "अनदेखा", "sync_conflict_status_none": "कोई नहीं", "sync_conflict_title": "सिंक विरोध", "sync_conflict_use_local": "स्थानीय उपयोग करें", "sync_conflict_use_server": "सर्वर उपयोग करें", "sync_fdroid_unavailable_body": "क्लाउड सिंक के लिए Google Play सेवाओं की आवश्यकता है और F-Droid बिल्ड में उपलब्ध नहीं है।", "sync_fdroid_unavailable_title": "F-Droid पर उपलब्ध नहीं", "settings_sync_brief_description": "क्लाउड सिंक आपको अपने सभी डिवाइस पर जानकारी सिंक करने देता है। सिंक के लिए सक्षम नहीं की गई जानकारी केवल इस डिवाइस पर रहती है।"}, "apple": {"settings_sync_off_notifications_warning": "क्रॉस-डिवाइस सिंक बंद है। Apple डिवाइस सूचनाएं प्राप्त करने के लिए TigerDuck सर्वर पर निर्भर करते हैं। अधिक जानकारी के लिए टैप करें।", "settings_sync_brief_description_ios": "क्लाउड सिंक आपको पुश नोटिफिकेशन प्राप्त करने और जानकारी सिंक करने देता है। सिंक के लिए सक्षम नहीं की गई जानकारी भी पुश नोटिफिकेशन के लिए सर्वर पर भेजी जाती है।"}},
    "hr": {"shared": {"onboarding_sync_not_shared_password": "Lozinka se nikada ne učitava", "onboarding_sync_shared_assignments": "Podaci o zadacima", "onboarding_sync_shared_courses": "Podaci o kolegijima", "onboarding_sync_shared_moodle_token": "Moodle token (šifriran)", "onboarding_sync_shared_student_id": "Studentski ID", "sync_conflict_message": "Neke stavke se razlikuju između ovog uređaja i poslužitelja:", "sync_conflict_status_completed": "Dovršeno", "sync_conflict_status_ignored": "Zanemareno", "sync_conflict_status_none": "Nema", "sync_conflict_title": "Sukob sinkronizacije", "sync_conflict_use_local": "Koristi lokalno", "sync_conflict_use_server": "Koristi poslužitelj", "sync_fdroid_unavailable_body": "Cloud Sync zahtijeva Google Play usluge i nije dostupan u F-Droid verziji.", "sync_fdroid_unavailable_title": "Nije dostupno na F-Droid", "settings_sync_brief_description": "Cloud Sync omogućuje sinkronizaciju odabranih podataka na svim uređajima. Podaci bez sinkronizacije ostaju samo na ovom uređaju."}, "apple": {"settings_sync_off_notifications_warning": "Sinkronizacija između uređaja je isključena. Apple uređaji ovise o TigerDuck poslužitelju za primanje obavijesti. Dodirnite za više informacija.", "settings_sync_brief_description_ios": "Cloud Sync omogućuje primanje push obavijesti i sinkronizaciju podataka. Podaci bez sinkronizacije i dalje se šalju na poslužitelj za push obavijesti."}},
    "hu": {"shared": {"onboarding_sync_not_shared_password": "A jelszó soha nem kerül feltöltésre", "onboarding_sync_shared_assignments": "Feladatadatok", "onboarding_sync_shared_courses": "Kurzusadatok", "onboarding_sync_shared_moodle_token": "Moodle token (titkosított)", "onboarding_sync_shared_student_id": "Hallgatói azonosító", "sync_conflict_message": "Egyes elemek eltérnek az eszköz és a szerver között:", "sync_conflict_status_completed": "Befejezett", "sync_conflict_status_ignored": "Figyelmen kívül hagyva", "sync_conflict_status_none": "Nincs", "sync_conflict_title": "Szinkronizálási ütközés", "sync_conflict_use_local": "Helyi használata", "sync_conflict_use_server": "Szerver használata", "sync_fdroid_unavailable_body": "A felhőszinkronizálás Google Play szolgáltatásokat igényel, és nem érhető el az F-Droid változatban.", "sync_fdroid_unavailable_title": "Nem érhető el az F-Droidon", "settings_sync_brief_description": "A felhőszinkronizálás lehetővé teszi a kiválasztott adatok szinkronizálását az összes eszközön. A nem engedélyezett adatok csak ezen az eszközön maradnak."}, "apple": {"settings_sync_off_notifications_warning": "Az eszközök közötti szinkronizálás ki van kapcsolva. Az Apple eszközök a TigerDuck szervertől függnek az értesítések fogadásához. Érintse meg a további információkért.", "settings_sync_brief_description_ios": "A felhőszinkronizálás lehetővé teszi push értesítések fogadását és adatok szinkronizálását. A nem szinkronizált adatok is elküldésre kerülnek a szerverre push értesítések céljából."}},
    "id": {"shared": {"onboarding_sync_not_shared_password": "Kata sandi tidak pernah diunggah", "onboarding_sync_shared_assignments": "Data tugas", "onboarding_sync_shared_courses": "Data mata kuliah", "onboarding_sync_shared_moodle_token": "Token Moodle (terenkripsi)", "onboarding_sync_shared_student_id": "ID Mahasiswa", "sync_conflict_message": "Beberapa item berbeda antara perangkat ini dan server:", "sync_conflict_status_completed": "Selesai", "sync_conflict_status_ignored": "Diabaikan", "sync_conflict_status_none": "Tidak ada", "sync_conflict_title": "Konflik Sinkronisasi", "sync_conflict_use_local": "Gunakan Lokal", "sync_conflict_use_server": "Gunakan Server", "sync_fdroid_unavailable_body": "Cloud Sync memerlukan Google Play Services dan tidak tersedia di build F-Droid.", "sync_fdroid_unavailable_title": "Tidak tersedia di F-Droid", "settings_sync_brief_description": "Cloud Sync memungkinkan Anda menyinkronkan informasi pilihan di semua perangkat. Informasi yang tidak diaktifkan tetap hanya di perangkat ini."}, "apple": {"settings_sync_off_notifications_warning": "Sinkronisasi lintas perangkat nonaktif. Perangkat Apple mengandalkan server TigerDuck untuk menerima notifikasi. Ketuk untuk info lebih lanjut.", "settings_sync_brief_description_ios": "Cloud Sync memungkinkan Anda menerima notifikasi push dan menyinkronkan informasi. Informasi yang tidak diaktifkan tetap dikirim ke server untuk notifikasi push."}},
    "is": {"shared": {"onboarding_sync_not_shared_password": "Lykilorð er aldrei hlaðið upp", "onboarding_sync_shared_assignments": "Verkefnagögn", "onboarding_sync_shared_courses": "Námskeiðagögn", "onboarding_sync_shared_moodle_token": "Moodle tóki (dulkóðaður)", "onboarding_sync_shared_student_id": "Nemandanúmer", "sync_conflict_message": "Sumir hlutir eru ólíkir á milli þessa tækis og þjónsins:", "sync_conflict_status_completed": "Lokið", "sync_conflict_status_ignored": "Hunsað", "sync_conflict_status_none": "Ekkert", "sync_conflict_title": "Samstillingarárekstur", "sync_conflict_use_local": "Nota staðbundið", "sync_conflict_use_server": "Nota þjón", "sync_fdroid_unavailable_body": "Skýjasamstilling krefst Google Play þjónustu og er ekki í boði í F-Droid útgáfunni.", "sync_fdroid_unavailable_title": "Ekki í boði á F-Droid", "settings_sync_brief_description": "Skýjasamstilling gerir þér kleift að samstilla valdar upplýsingar á öllum tækjum. Upplýsingar sem ekki eru virkar eru aðeins á þessu tæki."}, "apple": {"settings_sync_off_notifications_warning": "Samstilling milli tækja er slökkt. Apple tæki reiða sig á TigerDuck þjóninn til að fá tilkynningar. Ýttu til að fá frekari upplýsingar.", "settings_sync_brief_description_ios": "Skýjasamstilling gerir þér kleift að fá push-tilkynningar og samstilla upplýsingar. Óvirkar upplýsingar eru samt sendar á þjóninn fyrir push-tilkynningar."}},
    "it": {"shared": {"onboarding_sync_not_shared_password": "La password non viene mai caricata", "onboarding_sync_shared_assignments": "Dati dei compiti", "onboarding_sync_shared_courses": "Dati dei corsi", "onboarding_sync_shared_moodle_token": "Token Moodle (crittografato)", "onboarding_sync_shared_student_id": "Matricola", "sync_conflict_message": "Alcuni elementi differiscono tra questo dispositivo e il server:", "sync_conflict_status_completed": "Completato", "sync_conflict_status_ignored": "Ignorato", "sync_conflict_status_none": "Nessuno", "sync_conflict_title": "Conflitto di sincronizzazione", "sync_conflict_use_local": "Usa locale", "sync_conflict_use_server": "Usa server", "sync_fdroid_unavailable_body": "Cloud Sync richiede i servizi Google Play e non è disponibile nella versione F-Droid.", "sync_fdroid_unavailable_title": "Non disponibile su F-Droid", "settings_sync_brief_description": "Cloud Sync ti permette di sincronizzare le informazioni scelte su tutti i dispositivi. Le informazioni non abilitate restano solo su questo dispositivo."}, "apple": {"settings_sync_off_notifications_warning": "La sincronizzazione tra dispositivi è disattivata. I dispositivi Apple si affidano al server TigerDuck per le notifiche. Tocca per maggiori informazioni.", "settings_sync_brief_description_ios": "Cloud Sync ti permette di ricevere notifiche push e sincronizzare le informazioni. Le informazioni non abilitate vengono comunque inviate al server per le notifiche push."}},
    "ja": {"shared": {"onboarding_sync_not_shared_password": "パスワードはアップロードされません", "onboarding_sync_shared_assignments": "課題データ", "onboarding_sync_shared_courses": "コースデータ", "onboarding_sync_shared_moodle_token": "Moodleトークン（暗号化）", "onboarding_sync_shared_student_id": "学籍番号", "sync_conflict_message": "このデバイスとサーバーの間で一部の項目が異なります：", "sync_conflict_status_completed": "完了", "sync_conflict_status_ignored": "無視", "sync_conflict_status_none": "なし", "sync_conflict_title": "同期の競合", "sync_conflict_use_local": "ローカルを使用", "sync_conflict_use_server": "サーバーを使用", "sync_fdroid_unavailable_body": "クラウド同期にはGoogle Playサービスが必要です。F-Droidビルドでは利用できません。", "sync_fdroid_unavailable_title": "F-Droidでは利用不可", "settings_sync_brief_description": "クラウド同期を使用すると、選択した情報をすべてのデバイス間で同期できます。同期が有効でない情報はこのデバイスのみに保存されます。"}, "apple": {"settings_sync_off_notifications_warning": "デバイス間同期がオフです。Appleデバイスは通知の受信にTigerDuckサーバーを必要とします。詳細はタップしてください。", "settings_sync_brief_description_ios": "クラウド同期でプッシュ通知の受信と情報の同期ができます。同期が有効でない情報もプッシュ通知のためにサーバーに送信されます。"}},
    "kk": {"shared": {"onboarding_sync_not_shared_password": "Құпия сөз ешқашан жүктелмейді", "onboarding_sync_shared_assignments": "Тапсырма деректері", "onboarding_sync_shared_courses": "Курс деректері", "onboarding_sync_shared_moodle_token": "Moodle токені (шифрланған)", "onboarding_sync_shared_student_id": "Студент ID", "sync_conflict_message": "Кейбір элементтер осы құрылғы мен сервер арасында ерекшеленеді:", "sync_conflict_status_completed": "Аяқталды", "sync_conflict_status_ignored": "Елемеді", "sync_conflict_status_none": "Жоқ", "sync_conflict_title": "Синхрондау қайшылығы", "sync_conflict_use_local": "Жергілікті пайдалану", "sync_conflict_use_server": "Серверді пайдалану", "sync_fdroid_unavailable_body": "Бұлтты синхрондау Google Play қызметтерін қажет етеді және F-Droid нұсқасында қолжетімді емес.", "sync_fdroid_unavailable_title": "F-Droid-та қолжетімді емес", "settings_sync_brief_description": "Бұлтты синхрондау таңдалған ақпаратты барлық құрылғылар арасында синхрондауға мүмкіндік береді. Синхрондалмаған ақпарат тек осы құрылғыда қалады."}, "apple": {"settings_sync_off_notifications_warning": "Құрылғылар арасындағы синхрондау өшірулі. Apple құрылғылары хабарландырулар алу үшін TigerDuck серверіне тәуелді. Қосымша ақпарат алу үшін түртіңіз.", "settings_sync_brief_description_ios": "Бұлтты синхрондау push хабарландыруларды алуға және ақпаратты синхрондауға мүмкіндік береді. Синхрондалмаған ақпарат та push хабарландырулар үшін серверге жіберіледі."}},
    "kn": {"shared": {"onboarding_sync_not_shared_password": "ಪಾಸ್‌ವರ್ಡ್ ಎಂದಿಗೂ ಅಪ್‌ಲೋಡ್ ಆಗುವುದಿಲ್ಲ", "onboarding_sync_shared_assignments": "ಅಸೈನ್‌ಮೆಂಟ್ ಡೇಟಾ", "onboarding_sync_shared_courses": "ಕೋರ್ಸ್ ಡೇಟಾ", "onboarding_sync_shared_moodle_token": "Moodle ಟೋಕನ್ (ಎನ್‌ಕ್ರಿಪ್ಟೆಡ್)", "onboarding_sync_shared_student_id": "ವಿದ್ಯಾರ್ಥಿ ID", "sync_conflict_message": "ಈ ಸಾಧನ ಮತ್ತು ಸರ್ವರ್ ನಡುವೆ ಕೆಲವು ಐಟಂಗಳು ಭಿನ್ನವಾಗಿವೆ:", "sync_conflict_status_completed": "ಪೂರ್ಣ", "sync_conflict_status_ignored": "ನಿರ್ಲಕ್ಷಿಸಲಾಗಿದೆ", "sync_conflict_status_none": "ಯಾವುದೂ ಇಲ್ಲ", "sync_conflict_title": "ಸಿಂಕ್ ಸಂಘರ್ಷ", "sync_conflict_use_local": "ಸ್ಥಳೀಯ ಬಳಸಿ", "sync_conflict_use_server": "ಸರ್ವರ್ ಬಳಸಿ", "sync_fdroid_unavailable_body": "ಕ್ಲೌಡ್ ಸಿಂಕ್‌ಗೆ Google Play ಸೇವೆಗಳು ಅಗತ್ಯ ಮತ್ತು F-Droid ಬಿಲ್ಡ್‌ನಲ್ಲಿ ಲಭ್ಯವಿಲ್ಲ.", "sync_fdroid_unavailable_title": "F-Droid ನಲ್ಲಿ ಲಭ್ಯವಿಲ್ಲ", "settings_sync_brief_description": "ಕ್ಲೌಡ್ ಸಿಂಕ್ ನಿಮ್ಮ ಎಲ್ಲ ಸಾಧನಗಳಲ್ಲಿ ಮಾಹಿತಿಯನ್ನು ಸಿಂಕ್ ಮಾಡಲು ಅನುಮತಿಸುತ್ತದೆ. ಸಿಂಕ್‌ಗೆ ಸಕ್ರಿಯವಲ್ಲದ ಮಾಹಿತಿ ಈ ಸಾಧನದಲ್ಲಿ ಮಾತ್ರ ಉಳಿಯುತ್ತದೆ."}, "apple": {"settings_sync_off_notifications_warning": "ಕ್ರಾಸ್-ಡಿವೈಸ್ ಸಿಂಕ್ ಆಫ್ ಆಗಿದೆ. Apple ಸಾಧನಗಳು ಅಧಿಸೂಚನೆಗಳಿಗಾಗಿ TigerDuck ಸರ್ವರ್ ಅನ್ನು ಅವಲಂಬಿಸುತ್ತವೆ.", "settings_sync_brief_description_ios": "ಕ್ಲೌಡ್ ಸಿಂಕ್ ಪುಶ್ ಅಧಿಸೂಚನೆಗಳನ್ನು ಸ್ವೀಕರಿಸಲು ಮತ್ತು ಮಾಹಿತಿಯನ್ನು ಸಿಂಕ್ ಮಾಡಲು ಅನುಮತಿಸುತ್ತದೆ."}},
    "ko": {"shared": {"onboarding_sync_not_shared_password": "비밀번호는 업로드되지 않습니다", "onboarding_sync_shared_assignments": "과제 데이터", "onboarding_sync_shared_courses": "강의 데이터", "onboarding_sync_shared_moodle_token": "Moodle 토큰 (암호화)", "onboarding_sync_shared_student_id": "학번", "sync_conflict_message": "이 기기와 서버 간에 일부 항목이 다릅니다:", "sync_conflict_status_completed": "완료", "sync_conflict_status_ignored": "무시됨", "sync_conflict_status_none": "없음", "sync_conflict_title": "동기화 충돌", "sync_conflict_use_local": "로컬 사용", "sync_conflict_use_server": "서버 사용", "sync_fdroid_unavailable_body": "클라우드 동기화에는 Google Play 서비스가 필요하며 F-Droid 빌드에서는 사용할 수 없습니다.", "sync_fdroid_unavailable_title": "F-Droid에서 사용 불가", "settings_sync_brief_description": "클라우드 동기화를 사용하면 모든 기기에서 선택한 정보를 동기화할 수 있습니다. 동기화가 활성화되지 않은 정보는 이 기기에만 남습니다."}, "apple": {"settings_sync_off_notifications_warning": "기기 간 동기화가 꺼져 있습니다. Apple 기기는 알림 수신을 위해 TigerDuck 서버에 의존합니다. 자세한 내용을 보려면 탭하세요.", "settings_sync_brief_description_ios": "클라우드 동기화로 푸시 알림을 받고 정보를 동기화할 수 있습니다. 동기화가 활성화되지 않은 정보도 푸시 알림을 위해 서버에 전송됩니다."}},
    "lt": {"shared": {"onboarding_sync_not_shared_password": "Slaptažodis niekada neįkeliamas", "onboarding_sync_shared_assignments": "Užduočių duomenys", "onboarding_sync_shared_courses": "Kursų duomenys", "onboarding_sync_shared_moodle_token": "Moodle žetonas (šifruotas)", "onboarding_sync_shared_student_id": "Studento ID", "sync_conflict_message": "Kai kurie elementai skiriasi tarp šio įrenginio ir serverio:", "sync_conflict_status_completed": "Užbaigta", "sync_conflict_status_ignored": "Ignoruota", "sync_conflict_status_none": "Nėra", "sync_conflict_title": "Sinchronizacijos konfliktas", "sync_conflict_use_local": "Naudoti vietinį", "sync_conflict_use_server": "Naudoti serverį", "sync_fdroid_unavailable_body": "Debesų sinchronizacijai reikia „Google Play“ paslaugų ir ji nepasiekiama F-Droid versijoje.", "sync_fdroid_unavailable_title": "Nepasiekiama F-Droid", "settings_sync_brief_description": "Debesų sinchronizacija leidžia sinchronizuoti pasirinktą informaciją visuose įrenginiuose. Nesinchronizuota informacija lieka tik šiame įrenginyje."}, "apple": {"settings_sync_off_notifications_warning": "Sinchronizacija tarp įrenginių išjungta. Apple įrenginiai priklauso nuo TigerDuck serverio pranešimams gauti. Bakstelėkite daugiau informacijos.", "settings_sync_brief_description_ios": "Debesų sinchronizacija leidžia gauti push pranešimus ir sinchronizuoti informaciją. Nesinchronizuota informacija vis tiek siunčiama į serverį push pranešimams."}},
    "lv": {"shared": {"onboarding_sync_not_shared_password": "Parole nekad netiek augšupielādēta", "onboarding_sync_shared_assignments": "Uzdevumu dati", "onboarding_sync_shared_courses": "Kursu dati", "onboarding_sync_shared_moodle_token": "Moodle marķieris (šifrēts)", "onboarding_sync_shared_student_id": "Studenta ID", "sync_conflict_message": "Daži vienumi atšķiras starp šo ierīci un serveri:", "sync_conflict_status_completed": "Pabeigts", "sync_conflict_status_ignored": "Ignorēts", "sync_conflict_status_none": "Nav", "sync_conflict_title": "Sinhronizācijas konflikts", "sync_conflict_use_local": "Lietot lokālo", "sync_conflict_use_server": "Lietot serveri", "sync_fdroid_unavailable_body": "Mākoņsinhronizācijai nepieciešami Google Play pakalpojumi, un tā nav pieejama F-Droid versijā.", "sync_fdroid_unavailable_title": "Nav pieejams F-Droid", "settings_sync_brief_description": "Mākoņsinhronizācija ļauj sinhronizēt izvēlēto informāciju visās ierīcēs. Nesinhronizēta informācija paliek tikai šajā ierīcē."}, "apple": {"settings_sync_off_notifications_warning": "Sinhronizācija starp ierīcēm ir izslēgta. Apple ierīces paļaujas uz TigerDuck serveri paziņojumu saņemšanai. Pieskarieties, lai uzzinātu vairāk.", "settings_sync_brief_description_ios": "Mākoņsinhronizācija ļauj saņemt push paziņojumus un sinhronizēt informāciju. Nesinhronizēta informācija joprojām tiek nosūtīta uz serveri push paziņojumiem."}},
    "ml": {"shared": {"onboarding_sync_not_shared_password": "പാസ്‌വേഡ് ഒരിക്കലും അപ്‌ലോഡ് ചെയ്യില്ല", "onboarding_sync_shared_assignments": "അസൈൻമെന്റ് ഡാറ്റ", "onboarding_sync_shared_courses": "കോഴ്‌സ് ഡാറ്റ", "onboarding_sync_shared_moodle_token": "Moodle ടോക്കൺ (എൻക്രിപ്റ്റഡ്)", "onboarding_sync_shared_student_id": "വിദ്യാർത്ഥി ID", "sync_conflict_message": "ഈ ഉപകരണവും സെർവറും തമ്മിൽ ചില ഇനങ്ങൾ വ്യത്യാസപ്പെടുന്നു:", "sync_conflict_status_completed": "പൂർത്തിയായി", "sync_conflict_status_ignored": "അവഗണിച്ചു", "sync_conflict_status_none": "ഒന്നുമില്ല", "sync_conflict_title": "സിങ്ക് വൈരുദ്ധ്യം", "sync_conflict_use_local": "ലോക്കൽ ഉപയോഗിക്കുക", "sync_conflict_use_server": "സെർവർ ഉപയോഗിക്കുക", "sync_fdroid_unavailable_body": "ക്ലൗഡ് സിങ്കിന് Google Play സേവനങ്ങൾ ആവശ്യമാണ്, F-Droid ബിൽഡിൽ ലഭ്യമല്ല.", "sync_fdroid_unavailable_title": "F-Droid-ൽ ലഭ്യമല്ല", "settings_sync_brief_description": "ക്ലൗഡ് സിങ്ക് നിങ്ങളുടെ എല്ലാ ഉപകരണങ്ങളിലും വിവരങ്ങൾ സമന്വയിപ്പിക്കാൻ അനുവദിക്കുന്നു. സിങ്കിന് പ്രാപ്തമാക്കാത്ത വിവരങ്ങൾ ഈ ഉപകരണത്തിൽ മാത്രം നിലനിൽക്കും."}, "apple": {"settings_sync_off_notifications_warning": "ക്രോസ്-ഡിവൈസ് സിങ്ക് ഓഫ് ആണ്. Apple ഉപകരണങ്ങൾ അറിയിപ്പുകൾക്ക് TigerDuck സെർവറിനെ ആശ്രയിക്കുന്നു.", "settings_sync_brief_description_ios": "ക്ലൗഡ് സിങ്ക് പുഷ് അറിയിപ്പുകൾ സ്വീകരിക്കാനും വിവരങ്ങൾ സമന്വയിപ്പിക്കാനും അനുവദിക്കുന്നു."}},
    "mr": {"shared": {"onboarding_sync_not_shared_password": "पासवर्ड कधीही अपलोड केला जात नाही", "onboarding_sync_shared_assignments": "असाइनमेंट डेटा", "onboarding_sync_shared_courses": "कोर्स डेटा", "onboarding_sync_shared_moodle_token": "Moodle टोकन (एनक्रिप्टेड)", "onboarding_sync_shared_student_id": "विद्यार्थी ID", "sync_conflict_message": "या उपकरण आणि सर्व्हर दरम्यान काही आयटम भिन्न आहेत:", "sync_conflict_status_completed": "पूर्ण", "sync_conflict_status_ignored": "दुर्लक्षित", "sync_conflict_status_none": "काहीही नाही", "sync_conflict_title": "सिंक विरोध", "sync_conflict_use_local": "स्थानिक वापरा", "sync_conflict_use_server": "सर्व्हर वापरा", "sync_fdroid_unavailable_body": "क्लाउड सिंकसाठी Google Play सेवा आवश्यक आहेत आणि F-Droid बिल्डमध्ये उपलब्ध नाहीत.", "sync_fdroid_unavailable_title": "F-Droid वर उपलब्ध नाही", "settings_sync_brief_description": "क्लाउड सिंक तुम्हाला सर्व उपकरणांवर माहिती सिंक करण्याची परवानगी देते. सिंकसाठी सक्षम नसलेली माहिती फक्त या उपकरणावर राहते."}, "apple": {"settings_sync_off_notifications_warning": "क्रॉस-डिव्हाइस सिंक बंद आहे. Apple उपकरणे सूचनांसाठी TigerDuck सर्व्हरवर अवलंबून असतात.", "settings_sync_brief_description_ios": "क्लाउड सिंक पुश सूचना प्राप्त करण्यास आणि माहिती सिंक करण्यास अनुमती देते."}},
    "ms": {"shared": {"onboarding_sync_not_shared_password": "Kata laluan tidak pernah dimuat naik", "onboarding_sync_shared_assignments": "Data tugasan", "onboarding_sync_shared_courses": "Data kursus", "onboarding_sync_shared_moodle_token": "Token Moodle (disulitkan)", "onboarding_sync_shared_student_id": "ID Pelajar", "sync_conflict_message": "Beberapa item berbeza antara peranti ini dan pelayan:", "sync_conflict_status_completed": "Selesai", "sync_conflict_status_ignored": "Diabaikan", "sync_conflict_status_none": "Tiada", "sync_conflict_title": "Konflik Penyegerakan", "sync_conflict_use_local": "Guna Setempat", "sync_conflict_use_server": "Guna Pelayan", "sync_fdroid_unavailable_body": "Penyegerakan Awan memerlukan Perkhidmatan Google Play dan tidak tersedia dalam binaan F-Droid.", "sync_fdroid_unavailable_title": "Tidak tersedia di F-Droid", "settings_sync_brief_description": "Penyegerakan Awan membolehkan anda menyegerakkan maklumat pilihan anda di semua peranti. Maklumat yang tidak didayakan kekal pada peranti ini sahaja."}, "apple": {"settings_sync_off_notifications_warning": "Penyegerakan merentas peranti dimatikan. Peranti Apple bergantung pada pelayan TigerDuck untuk menerima pemberitahuan. Ketik untuk maklumat lanjut.", "settings_sync_brief_description_ios": "Penyegerakan Awan membolehkan anda menerima pemberitahuan push dan menyegerakkan maklumat. Maklumat yang tidak didayakan masih dihantar ke pelayan untuk pemberitahuan push."}},
    "nl": {"shared": {"onboarding_sync_not_shared_password": "Wachtwoord wordt nooit geüpload", "onboarding_sync_shared_assignments": "Opdrachtgegevens", "onboarding_sync_shared_courses": "Cursusgegevens", "onboarding_sync_shared_moodle_token": "Moodle-token (versleuteld)", "onboarding_sync_shared_student_id": "Studentnummer", "sync_conflict_message": "Sommige items verschillen tussen dit apparaat en de server:", "sync_conflict_status_completed": "Voltooid", "sync_conflict_status_ignored": "Genegeerd", "sync_conflict_status_none": "Geen", "sync_conflict_title": "Synchronisatieconflict", "sync_conflict_use_local": "Lokaal gebruiken", "sync_conflict_use_server": "Server gebruiken", "sync_fdroid_unavailable_body": "Cloud Sync vereist Google Play-services en is niet beschikbaar in de F-Droid-versie.", "sync_fdroid_unavailable_title": "Niet beschikbaar op F-Droid", "settings_sync_brief_description": "Cloud Sync synchroniseert je gekozen informatie op al je apparaten. Niet-ingeschakelde informatie blijft alleen op dit apparaat."}, "apple": {"settings_sync_off_notifications_warning": "Synchronisatie tussen apparaten is uitgeschakeld. Apple-apparaten zijn afhankelijk van de TigerDuck-server voor meldingen. Tik voor meer info.", "settings_sync_brief_description_ios": "Cloud Sync laat je pushmeldingen ontvangen en informatie synchroniseren. Niet-ingeschakelde informatie wordt toch naar de server gestuurd voor pushmeldingen."}},
    "no": {"shared": {"onboarding_sync_not_shared_password": "Passordet lastes aldri opp", "onboarding_sync_shared_assignments": "Oppgavedata", "onboarding_sync_shared_courses": "Kursdata", "onboarding_sync_shared_moodle_token": "Moodle-token (kryptert)", "onboarding_sync_shared_student_id": "Student-ID", "sync_conflict_message": "Noen elementer er forskjellige mellom denne enheten og serveren:", "sync_conflict_status_completed": "Fullført", "sync_conflict_status_ignored": "Ignorert", "sync_conflict_status_none": "Ingen", "sync_conflict_title": "Synkroniseringskonflikt", "sync_conflict_use_local": "Bruk lokal", "sync_conflict_use_server": "Bruk server", "sync_fdroid_unavailable_body": "Skysynkronisering krever Google Play-tjenester og er ikke tilgjengelig i F-Droid-versjonen.", "sync_fdroid_unavailable_title": "Ikke tilgjengelig på F-Droid", "settings_sync_brief_description": "Skysynkronisering lar deg synkronisere valgt informasjon på alle enheter. Informasjon uten synkronisering forblir kun på denne enheten."}, "apple": {"settings_sync_off_notifications_warning": "Synkronisering mellom enheter er av. Apple-enheter er avhengige av TigerDuck-serveren for varsler. Trykk for mer info.", "settings_sync_brief_description_ios": "Skysynkronisering lar deg motta push-varsler og synkronisere informasjon. Informasjon uten synkronisering sendes likevel til serveren for push-varsler."}},
    "pa": {"shared": {"onboarding_sync_not_shared_password": "ਪਾਸਵਰਡ ਕਦੇ ਅੱਪਲੋਡ ਨਹੀਂ ਹੁੰਦਾ", "onboarding_sync_shared_assignments": "ਅਸਾਈਨਮੈਂਟ ਡੇਟਾ", "onboarding_sync_shared_courses": "ਕੋਰਸ ਡੇਟਾ", "onboarding_sync_shared_moodle_token": "Moodle ਟੋਕਨ (ਐਨਕ੍ਰਿਪਟਿਡ)", "onboarding_sync_shared_student_id": "ਵਿਦਿਆਰਥੀ ID", "sync_conflict_message": "ਇਸ ਡਿਵਾਈਸ ਅਤੇ ਸਰਵਰ ਵਿਚਕਾਰ ਕੁਝ ਆਈਟਮ ਵੱਖਰੇ ਹਨ:", "sync_conflict_status_completed": "ਪੂਰਾ", "sync_conflict_status_ignored": "ਅਣਦੇਖਿਆ", "sync_conflict_status_none": "ਕੋਈ ਨਹੀਂ", "sync_conflict_title": "ਸਿੰਕ ਵਿਵਾਦ", "sync_conflict_use_local": "ਸਥਾਨਕ ਵਰਤੋ", "sync_conflict_use_server": "ਸਰਵਰ ਵਰਤੋ", "sync_fdroid_unavailable_body": "ਕਲਾਊਡ ਸਿੰਕ ਲਈ Google Play ਸੇਵਾਵਾਂ ਲੋੜੀਂਦੀਆਂ ਹਨ ਅਤੇ F-Droid ਬਿਲਡ ਵਿੱਚ ਉਪਲਬਧ ਨਹੀਂ ਹੈ।", "sync_fdroid_unavailable_title": "F-Droid ਤੇ ਉਪਲਬਧ ਨਹੀਂ", "settings_sync_brief_description": "ਕਲਾਊਡ ਸਿੰਕ ਤੁਹਾਨੂੰ ਸਾਰੇ ਡਿਵਾਈਸਾਂ ਤੇ ਜਾਣਕਾਰੀ ਸਿੰਕ ਕਰਨ ਦਿੰਦਾ ਹੈ। ਸਿੰਕ ਲਈ ਸਮਰੱਥ ਨਾ ਹੋਈ ਜਾਣਕਾਰੀ ਸਿਰਫ਼ ਇਸ ਡਿਵਾਈਸ ਤੇ ਰਹਿੰਦੀ ਹੈ।"}, "apple": {"settings_sync_off_notifications_warning": "ਕ੍ਰਾਸ-ਡਿਵਾਈਸ ਸਿੰਕ ਬੰਦ ਹੈ। Apple ਡਿਵਾਈਸ ਸੂਚਨਾਵਾਂ ਲਈ TigerDuck ਸਰਵਰ ਤੇ ਨਿਰਭਰ ਕਰਦੇ ਹਨ।", "settings_sync_brief_description_ios": "ਕਲਾਊਡ ਸਿੰਕ ਪੁਸ਼ ਸੂਚਨਾਵਾਂ ਪ੍ਰਾਪਤ ਕਰਨ ਅਤੇ ਜਾਣਕਾਰੀ ਸਿੰਕ ਕਰਨ ਦਿੰਦਾ ਹੈ।"}},
    "pl": {"shared": {"onboarding_sync_not_shared_password": "Hasło nigdy nie jest przesyłane", "onboarding_sync_shared_assignments": "Dane zadań", "onboarding_sync_shared_courses": "Dane kursów", "onboarding_sync_shared_moodle_token": "Token Moodle (zaszyfrowany)", "onboarding_sync_shared_student_id": "Numer studenta", "sync_conflict_message": "Niektóre elementy różnią się między tym urządzeniem a serwerem:", "sync_conflict_status_completed": "Ukończone", "sync_conflict_status_ignored": "Zignorowane", "sync_conflict_status_none": "Brak", "sync_conflict_title": "Konflikt synchronizacji", "sync_conflict_use_local": "Użyj lokalnych", "sync_conflict_use_server": "Użyj serwera", "sync_fdroid_unavailable_body": "Synchronizacja w chmurze wymaga usług Google Play i nie jest dostępna w wersji F-Droid.", "sync_fdroid_unavailable_title": "Niedostępne na F-Droid", "settings_sync_brief_description": "Synchronizacja w chmurze umożliwia synchronizację wybranych informacji na wszystkich urządzeniach. Informacje bez synchronizacji pozostają tylko na tym urządzeniu."}, "apple": {"settings_sync_off_notifications_warning": "Synchronizacja między urządzeniami jest wyłączona. Urządzenia Apple polegają na serwerze TigerDuck w celu otrzymywania powiadomień. Dotknij, aby uzyskać więcej informacji.", "settings_sync_brief_description_ios": "Synchronizacja w chmurze umożliwia otrzymywanie powiadomień push i synchronizację informacji. Informacje bez synchronizacji są nadal wysyłane na serwer w celu powiadomień push."}},
    "pt-BR": {"shared": {"onboarding_sync_not_shared_password": "A senha nunca é enviada", "onboarding_sync_shared_assignments": "Dados das tarefas", "onboarding_sync_shared_courses": "Dados dos cursos", "onboarding_sync_shared_moodle_token": "Token Moodle (criptografado)", "onboarding_sync_shared_student_id": "ID do estudante", "sync_conflict_message": "Alguns itens diferem entre este dispositivo e o servidor:", "sync_conflict_status_completed": "Concluído", "sync_conflict_status_ignored": "Ignorado", "sync_conflict_status_none": "Nenhum", "sync_conflict_title": "Conflito de sincronização", "sync_conflict_use_local": "Usar local", "sync_conflict_use_server": "Usar servidor", "sync_fdroid_unavailable_body": "A sincronização na nuvem requer os serviços do Google Play e não está disponível na versão F-Droid.", "sync_fdroid_unavailable_title": "Não disponível no F-Droid", "settings_sync_brief_description": "A sincronização na nuvem permite sincronizar as informações escolhidas em todos os seus dispositivos. As informações não ativadas permanecem apenas neste dispositivo."}, "apple": {"settings_sync_off_notifications_warning": "A sincronização entre dispositivos está desativada. Dispositivos Apple dependem do servidor TigerDuck para receber notificações. Toque para mais informações.", "settings_sync_brief_description_ios": "A sincronização na nuvem permite receber notificações push e sincronizar informações. As informações não ativadas ainda são enviadas ao servidor para notificações push."}},
    "pt-PT": {"shared": {"onboarding_sync_not_shared_password": "A palavra-passe nunca é carregada", "onboarding_sync_shared_assignments": "Dados das tarefas", "onboarding_sync_shared_courses": "Dados dos cursos", "onboarding_sync_shared_moodle_token": "Token Moodle (encriptado)", "onboarding_sync_shared_student_id": "Número de estudante", "sync_conflict_message": "Alguns itens diferem entre este dispositivo e o servidor:", "sync_conflict_status_completed": "Concluído", "sync_conflict_status_ignored": "Ignorado", "sync_conflict_status_none": "Nenhum", "sync_conflict_title": "Conflito de sincronização", "sync_conflict_use_local": "Usar local", "sync_conflict_use_server": "Usar servidor", "sync_fdroid_unavailable_body": "A sincronização na nuvem requer os serviços Google Play e não está disponível na versão F-Droid.", "sync_fdroid_unavailable_title": "Não disponível no F-Droid", "settings_sync_brief_description": "A sincronização na nuvem permite sincronizar as informações escolhidas em todos os dispositivos. As informações não ativadas permanecem apenas neste dispositivo."}, "apple": {"settings_sync_off_notifications_warning": "A sincronização entre dispositivos está desativada. Os dispositivos Apple dependem do servidor TigerDuck para receber notificações. Toque para mais informações.", "settings_sync_brief_description_ios": "A sincronização na nuvem permite receber notificações push e sincronizar informações. As informações não ativadas são enviadas na mesma para o servidor para notificações push."}},
    "ro": {"shared": {"onboarding_sync_not_shared_password": "Parola nu este încărcată niciodată", "onboarding_sync_shared_assignments": "Date teme", "onboarding_sync_shared_courses": "Date cursuri", "onboarding_sync_shared_moodle_token": "Token Moodle (criptat)", "onboarding_sync_shared_student_id": "ID student", "sync_conflict_message": "Unele elemente diferă între acest dispozitiv și server:", "sync_conflict_status_completed": "Finalizat", "sync_conflict_status_ignored": "Ignorat", "sync_conflict_status_none": "Niciunul", "sync_conflict_title": "Conflict de sincronizare", "sync_conflict_use_local": "Folosește local", "sync_conflict_use_server": "Folosește server", "sync_fdroid_unavailable_body": "Sincronizarea cloud necesită servicii Google Play și nu este disponibilă în versiunea F-Droid.", "sync_fdroid_unavailable_title": "Indisponibil pe F-Droid", "settings_sync_brief_description": "Sincronizarea cloud vă permite să sincronizați informațiile alese pe toate dispozitivele. Informațiile neactivate rămân doar pe acest dispozitiv."}, "apple": {"settings_sync_off_notifications_warning": "Sincronizarea între dispozitive este dezactivată. Dispozitivele Apple se bazează pe serverul TigerDuck pentru notificări. Atingeți pentru mai multe informații.", "settings_sync_brief_description_ios": "Sincronizarea cloud vă permite să primiți notificări push și să sincronizați informații. Informațiile neactivate sunt trimise oricum la server pentru notificări push."}},
    "ru": {"shared": {"onboarding_sync_not_shared_password": "Пароль никогда не загружается", "onboarding_sync_shared_assignments": "Данные заданий", "onboarding_sync_shared_courses": "Данные курсов", "onboarding_sync_shared_moodle_token": "Токен Moodle (зашифрован)", "onboarding_sync_shared_student_id": "Студенческий ID", "sync_conflict_message": "Некоторые элементы отличаются между этим устройством и сервером:", "sync_conflict_status_completed": "Завершено", "sync_conflict_status_ignored": "Проигнорировано", "sync_conflict_status_none": "Нет", "sync_conflict_title": "Конфликт синхронизации", "sync_conflict_use_local": "Использовать локальное", "sync_conflict_use_server": "Использовать сервер", "sync_fdroid_unavailable_body": "Облачная синхронизация требует сервисов Google Play и недоступна в сборке F-Droid.", "sync_fdroid_unavailable_title": "Недоступно в F-Droid", "settings_sync_brief_description": "Облачная синхронизация позволяет синхронизировать выбранную информацию на всех устройствах. Информация без синхронизации остаётся только на этом устройстве."}, "apple": {"settings_sync_off_notifications_warning": "Межустройственная синхронизация отключена. Устройства Apple зависят от сервера TigerDuck для получения уведомлений. Нажмите для подробностей.", "settings_sync_brief_description_ios": "Облачная синхронизация позволяет получать push-уведомления и синхронизировать информацию. Информация без синхронизации всё равно отправляется на сервер для push-уведомлений."}},
    "sk": {"shared": {"onboarding_sync_not_shared_password": "Heslo sa nikdy nenahráva", "onboarding_sync_shared_assignments": "Dáta úloh", "onboarding_sync_shared_courses": "Dáta kurzov", "onboarding_sync_shared_moodle_token": "Moodle token (šifrovaný)", "onboarding_sync_shared_student_id": "Študentské ID", "sync_conflict_message": "Niektoré položky sa líšia medzi týmto zariadením a serverom:", "sync_conflict_status_completed": "Dokončené", "sync_conflict_status_ignored": "Ignorované", "sync_conflict_status_none": "Žiadne", "sync_conflict_title": "Konflikt synchronizácie", "sync_conflict_use_local": "Použiť miestne", "sync_conflict_use_server": "Použiť server", "sync_fdroid_unavailable_body": "Cloudová synchronizácia vyžaduje služby Google Play a nie je dostupná vo verzii F-Droid.", "sync_fdroid_unavailable_title": "Nedostupné na F-Droid", "settings_sync_brief_description": "Cloudová synchronizácia umožňuje synchronizovať vybrané informácie na všetkých zariadeniach. Neaktivované informácie zostávajú iba na tomto zariadení."}, "apple": {"settings_sync_off_notifications_warning": "Synchronizácia medzi zariadeniami je vypnutá. Zariadenia Apple sa spoliehajú na server TigerDuck pre prijímanie oznámení. Klepnite pre viac informácií.", "settings_sync_brief_description_ios": "Cloudová synchronizácia umožňuje prijímať push oznámenia a synchronizovať informácie. Neaktivované informácie sa aj tak odosielajú na server pre push oznámenia."}},
    "sl": {"shared": {"onboarding_sync_not_shared_password": "Geslo se nikoli ne naloži", "onboarding_sync_shared_assignments": "Podatki o nalogah", "onboarding_sync_shared_courses": "Podatki o predmetih", "onboarding_sync_shared_moodle_token": "Moodle žeton (šifriran)", "onboarding_sync_shared_student_id": "Študentski ID", "sync_conflict_message": "Nekateri elementi se razlikujejo med to napravo in strežnikom:", "sync_conflict_status_completed": "Dokončano", "sync_conflict_status_ignored": "Prezrto", "sync_conflict_status_none": "Brez", "sync_conflict_title": "Konflikt sinhronizacije", "sync_conflict_use_local": "Uporabi lokalno", "sync_conflict_use_server": "Uporabi strežnik", "sync_fdroid_unavailable_body": "Sinhronizacija v oblaku zahteva storitve Google Play in ni na voljo v različici F-Droid.", "sync_fdroid_unavailable_title": "Ni na voljo na F-Droid", "settings_sync_brief_description": "Sinhronizacija v oblaku omogoča sinhronizacijo izbranih podatkov med vsemi napravami. Neaktivni podatki ostanejo samo na tej napravi."}, "apple": {"settings_sync_off_notifications_warning": "Sinhronizacija med napravami je izklopljena. Naprave Apple se za obvestila zanašajo na strežnik TigerDuck. Tapnite za več informacij.", "settings_sync_brief_description_ios": "Sinhronizacija v oblaku omogoča prejemanje push obvestil in sinhronizacijo podatkov. Neaktivirani podatki se kljub temu pošljejo na strežnik za push obvestila."}},
    "sr": {"shared": {"onboarding_sync_not_shared_password": "Лозинка се никада не отпрема", "onboarding_sync_shared_assignments": "Подаци о задацима", "onboarding_sync_shared_courses": "Подаци о курсевима", "onboarding_sync_shared_moodle_token": "Moodle токен (шифрован)", "onboarding_sync_shared_student_id": "Студентски ID", "sync_conflict_message": "Неки елементи се разликују између овог уређаја и сервера:", "sync_conflict_status_completed": "Завршено", "sync_conflict_status_ignored": "Игнорисано", "sync_conflict_status_none": "Ниједан", "sync_conflict_title": "Конфликт синхронизације", "sync_conflict_use_local": "Користи локално", "sync_conflict_use_server": "Користи сервер", "sync_fdroid_unavailable_body": "Синхронизација у облаку захтева Google Play услуге и није доступна у F-Droid верзији.", "sync_fdroid_unavailable_title": "Није доступно на F-Droid", "settings_sync_brief_description": "Синхронизација у облаку омогућава синхронизацију изабраних информација на свим уређајима. Неактивиране информације остају само на овом уређају."}, "apple": {"settings_sync_off_notifications_warning": "Синхронизација између уређаја је искључена. Apple уређаји зависе од TigerDuck сервера за примање обавештења.", "settings_sync_brief_description_ios": "Синхронизација у облаку омогућава пријем push обавештења и синхронизацију информација."}},
    "sv": {"shared": {"onboarding_sync_not_shared_password": "Lösenordet laddas aldrig upp", "onboarding_sync_shared_assignments": "Uppgiftsdata", "onboarding_sync_shared_courses": "Kursdata", "onboarding_sync_shared_moodle_token": "Moodle-token (krypterad)", "onboarding_sync_shared_student_id": "Student-ID", "sync_conflict_message": "Vissa objekt skiljer sig mellan den här enheten och servern:", "sync_conflict_status_completed": "Slutförd", "sync_conflict_status_ignored": "Ignorerad", "sync_conflict_status_none": "Ingen", "sync_conflict_title": "Synkroniseringskonflikt", "sync_conflict_use_local": "Använd lokal", "sync_conflict_use_server": "Använd server", "sync_fdroid_unavailable_body": "Molnsynkronisering kräver Google Play-tjänster och är inte tillgänglig i F-Droid-versionen.", "sync_fdroid_unavailable_title": "Inte tillgänglig på F-Droid", "settings_sync_brief_description": "Molnsynkronisering låter dig synkronisera vald information på alla enheter. Information utan synkronisering förblir bara på den här enheten."}, "apple": {"settings_sync_off_notifications_warning": "Synkronisering mellan enheter är avstängd. Apple-enheter är beroende av TigerDuck-servern för aviseringar. Tryck för mer info.", "settings_sync_brief_description_ios": "Molnsynkronisering låter dig ta emot push-aviseringar och synkronisera information. Information utan synkronisering skickas ändå till servern för push-aviseringar."}},
    "ta": {"shared": {"onboarding_sync_not_shared_password": "கடவுச்சொல் ஒருபோதும் பதிவேற்றப்படாது", "onboarding_sync_shared_assignments": "பணி தரவு", "onboarding_sync_shared_courses": "பாடநெறி தரவு", "onboarding_sync_shared_moodle_token": "Moodle டோக்கன் (குறியாக்கம்)", "onboarding_sync_shared_student_id": "மாணவர் ID", "sync_conflict_message": "இந்த சாதனத்திற்கும் சேவையகத்திற்கும் இடையே சில உருப்படிகள் வேறுபடுகின்றன:", "sync_conflict_status_completed": "முடிந்தது", "sync_conflict_status_ignored": "புறக்கணிக்கப்பட்டது", "sync_conflict_status_none": "எதுவுமில்லை", "sync_conflict_title": "ஒத்திசைவு முரண்பாடு", "sync_conflict_use_local": "உள்ளூர் பயன்படுத்து", "sync_conflict_use_server": "சேவையகம் பயன்படுத்து", "sync_fdroid_unavailable_body": "கிளவுட் ஒத்திசைவுக்கு Google Play சேவைகள் தேவை, F-Droid பதிப்பில் கிடைக்காது.", "sync_fdroid_unavailable_title": "F-Droid இல் கிடைக்காது", "settings_sync_brief_description": "கிளவுட் ஒத்திசைவு உங்கள் அனைத்து சாதனங்களிலும் தகவலை ஒத்திசைக்க அனுமதிக்கிறது. ஒத்திசைவுக்கு இயக்கப்படாத தகவல் இந்த சாதனத்தில் மட்டுமே இருக்கும்."}, "apple": {"settings_sync_off_notifications_warning": "குறுக்கு-சாதன ஒத்திசைவு முடக்கப்பட்டுள்ளது. Apple சாதனங்கள் அறிவிப்புகளுக்கு TigerDuck சேவையகத்தை நம்பியுள்ளன.", "settings_sync_brief_description_ios": "கிளவுட் ஒத்திசைவு புஷ் அறிவிப்புகளைப் பெறவும் தகவலை ஒத்திசைக்கவும் அனுமதிக்கிறது."}},
    "te": {"shared": {"onboarding_sync_not_shared_password": "పాస్‌వర్డ్ ఎప్పటికీ అప్‌లోడ్ చేయబడదు", "onboarding_sync_shared_assignments": "అసైన్‌మెంట్ డేటా", "onboarding_sync_shared_courses": "కోర్సు డేటా", "onboarding_sync_shared_moodle_token": "Moodle టోకెన్ (ఎన్‌క్రిప్టెడ్)", "onboarding_sync_shared_student_id": "విద్యార్థి ID", "sync_conflict_message": "ఈ పరికరం మరియు సర్వర్ మధ్య కొన్ని అంశాలు భిన్నంగా ఉన్నాయి:", "sync_conflict_status_completed": "పూర్తయింది", "sync_conflict_status_ignored": "విస్మరించబడింది", "sync_conflict_status_none": "ఏమీ లేదు", "sync_conflict_title": "సింక్ వైరుధ్యం", "sync_conflict_use_local": "స్థానికం ఉపయోగించు", "sync_conflict_use_server": "సర్వర్ ఉపయోగించు", "sync_fdroid_unavailable_body": "క్లౌడ్ సింక్‌కు Google Play సేవలు అవసరం, F-Droid బిల్డ్‌లో అందుబాటులో లేదు.", "sync_fdroid_unavailable_title": "F-Droid లో అందుబాటులో లేదు", "settings_sync_brief_description": "క్లౌడ్ సింక్ మీ అన్ని పరికరాలలో సమాచారాన్ని సమకాలీకరించడానికి అనుమతిస్తుంది. సింక్‌కు ప్రారంభించబడని సమాచారం ఈ పరికరంలో మాత్రమే ఉంటుంది."}, "apple": {"settings_sync_off_notifications_warning": "క్రాస్-డివైస్ సింక్ ఆఫ్. Apple పరికరాలు నోటిఫికేషన్‌ల కోసం TigerDuck సర్వర్‌పై ఆధారపడతాయి.", "settings_sync_brief_description_ios": "క్లౌడ్ సింక్ పుష్ నోటిఫికేషన్‌లను స్వీకరించడానికి మరియు సమాచారాన్ని సమకాలీకరించడానికి అనుమతిస్తుంది."}},
    "th": {"shared": {"onboarding_sync_not_shared_password": "รหัสผ่านจะไม่ถูกอัปโหลด", "onboarding_sync_shared_assignments": "ข้อมูลงาน", "onboarding_sync_shared_courses": "ข้อมูลรายวิชา", "onboarding_sync_shared_moodle_token": "โทเค็น Moodle (เข้ารหัส)", "onboarding_sync_shared_student_id": "รหัสนักศึกษา", "sync_conflict_message": "บางรายการแตกต่างระหว่างอุปกรณ์นี้กับเซิร์ฟเวอร์:", "sync_conflict_status_completed": "เสร็จสิ้น", "sync_conflict_status_ignored": "ข้ามไป", "sync_conflict_status_none": "ไม่มี", "sync_conflict_title": "ความขัดแย้งในการซิงค์", "sync_conflict_use_local": "ใช้ของเครื่อง", "sync_conflict_use_server": "ใช้ของเซิร์ฟเวอร์", "sync_fdroid_unavailable_body": "การซิงค์คลาวด์ต้องการ Google Play Services และไม่พร้อมใช้งานในเวอร์ชัน F-Droid", "sync_fdroid_unavailable_title": "ไม่พร้อมใช้งานบน F-Droid", "settings_sync_brief_description": "การซิงค์คลาวด์ช่วยให้คุณซิงค์ข้อมูลที่เลือกในอุปกรณ์ทั้งหมด ข้อมูลที่ไม่ได้เปิดใช้จะอยู่ในอุปกรณ์นี้เท่านั้น"}, "apple": {"settings_sync_off_notifications_warning": "การซิงค์ข้ามอุปกรณ์ปิดอยู่ อุปกรณ์ Apple ต้องพึ่งเซิร์ฟเวอร์ TigerDuck เพื่อรับการแจ้งเตือน แตะเพื่อดูข้อมูลเพิ่มเติม", "settings_sync_brief_description_ios": "การซิงค์คลาวด์ช่วยให้คุณรับการแจ้งเตือนแบบพุชและซิงค์ข้อมูล ข้อมูลที่ไม่ได้เปิดใช้จะยังคงถูกส่งไปยังเซิร์ฟเวอร์เพื่อการแจ้งเตือนแบบพุช"}},
    "tr": {"shared": {"onboarding_sync_not_shared_password": "Şifre asla yüklenmez", "onboarding_sync_shared_assignments": "Ödev verileri", "onboarding_sync_shared_courses": "Ders verileri", "onboarding_sync_shared_moodle_token": "Moodle jetonu (şifreli)", "onboarding_sync_shared_student_id": "Öğrenci numarası", "sync_conflict_message": "Bu cihaz ile sunucu arasında bazı öğeler farklı:", "sync_conflict_status_completed": "Tamamlandı", "sync_conflict_status_ignored": "Yok sayıldı", "sync_conflict_status_none": "Yok", "sync_conflict_title": "Senkronizasyon Çakışması", "sync_conflict_use_local": "Yereli Kullan", "sync_conflict_use_server": "Sunucuyu Kullan", "sync_fdroid_unavailable_body": "Bulut Senkronizasyon, Google Play Hizmetleri gerektirir ve F-Droid sürümünde mevcut değildir.", "sync_fdroid_unavailable_title": "F-Droid'de mevcut değil", "settings_sync_brief_description": "Bulut Senkronizasyon, seçtiğiniz bilgileri tüm cihazlarınızda senkronize etmenizi sağlar. Etkinleştirilmemiş bilgiler yalnızca bu cihazda kalır."}, "apple": {"settings_sync_off_notifications_warning": "Cihazlar arası senkronizasyon kapalı. Apple cihazları bildirimler için TigerDuck sunucusuna bağımlıdır. Daha fazla bilgi için dokunun.", "settings_sync_brief_description_ios": "Bulut Senkronizasyon, push bildirimleri almanızı ve bilgileri senkronize etmenizi sağlar. Etkinleştirilmemiş bilgiler push bildirimleri için yine de sunucuya gönderilir."}},
    "uk": {"shared": {"onboarding_sync_not_shared_password": "Пароль ніколи не завантажується", "onboarding_sync_shared_assignments": "Дані завдань", "onboarding_sync_shared_courses": "Дані курсів", "onboarding_sync_shared_moodle_token": "Токен Moodle (зашифрований)", "onboarding_sync_shared_student_id": "Студентський ID", "sync_conflict_message": "Деякі елементи відрізняються між цим пристроєм та сервером:", "sync_conflict_status_completed": "Завершено", "sync_conflict_status_ignored": "Проігноровано", "sync_conflict_status_none": "Немає", "sync_conflict_title": "Конфлікт синхронізації", "sync_conflict_use_local": "Використати локальне", "sync_conflict_use_server": "Використати сервер", "sync_fdroid_unavailable_body": "Хмарна синхронізація потребує сервісів Google Play і недоступна у збірці F-Droid.", "sync_fdroid_unavailable_title": "Недоступно в F-Droid", "settings_sync_brief_description": "Хмарна синхронізація дозволяє синхронізувати обрану інформацію на всіх пристроях. Інформація без синхронізації залишається лише на цьому пристрої."}, "apple": {"settings_sync_off_notifications_warning": "Синхронізація між пристроями вимкнена. Пристрої Apple залежать від сервера TigerDuck для отримання сповіщень. Натисніть для деталей.", "settings_sync_brief_description_ios": "Хмарна синхронізація дозволяє отримувати push-сповіщення та синхронізувати інформацію. Інформація без синхронізації все одно надсилається на сервер для push-сповіщень."}},
    "ur": {"shared": {"onboarding_sync_not_shared_password": "پاس ورڈ کبھی اپ لوڈ نہیں ہوتا", "onboarding_sync_shared_assignments": "اسائنمنٹ ڈیٹا", "onboarding_sync_shared_courses": "کورس ڈیٹا", "onboarding_sync_shared_moodle_token": "Moodle ٹوکن (خفیہ کردہ)", "onboarding_sync_shared_student_id": "طالب علم ID", "sync_conflict_message": "اس آلے اور سرور کے درمیان کچھ آئٹمز مختلف ہیں:", "sync_conflict_status_completed": "مکمل", "sync_conflict_status_ignored": "نظرانداز", "sync_conflict_status_none": "کوئی نہیں", "sync_conflict_title": "مطابقت پذیری تنازعہ", "sync_conflict_use_local": "مقامی استعمال کریں", "sync_conflict_use_server": "سرور استعمال کریں", "sync_fdroid_unavailable_body": "کلاؤڈ مطابقت پذیری کے لیے Google Play خدمات درکار ہیں اور F-Droid میں دستیاب نہیں ہے۔", "sync_fdroid_unavailable_title": "F-Droid پر دستیاب نہیں", "settings_sync_brief_description": "کلاؤڈ مطابقت پذیری آپ کو تمام آلات پر معلومات مطابقت پذیر کرنے دیتی ہے۔ فعال نہ کی گئی معلومات صرف اس آلے پر رہتی ہیں۔"}, "apple": {"settings_sync_off_notifications_warning": "کراس ڈیوائس مطابقت پذیری بند ہے۔ Apple آلات اطلاعات کے لیے TigerDuck سرور پر انحصار کرتے ہیں۔", "settings_sync_brief_description_ios": "کلاؤڈ مطابقت پذیری پش اطلاعات وصول کرنے اور معلومات مطابقت پذیر کرنے دیتی ہے۔"}},
    "vi": {"shared": {"onboarding_sync_not_shared_password": "Mật khẩu không bao giờ được tải lên", "onboarding_sync_shared_assignments": "Dữ liệu bài tập", "onboarding_sync_shared_courses": "Dữ liệu khóa học", "onboarding_sync_shared_moodle_token": "Token Moodle (mã hóa)", "onboarding_sync_shared_student_id": "Mã sinh viên", "sync_conflict_message": "Một số mục khác nhau giữa thiết bị này và máy chủ:", "sync_conflict_status_completed": "Đã hoàn thành", "sync_conflict_status_ignored": "Đã bỏ qua", "sync_conflict_status_none": "Không có", "sync_conflict_title": "Xung đột đồng bộ", "sync_conflict_use_local": "Dùng cục bộ", "sync_conflict_use_server": "Dùng máy chủ", "sync_fdroid_unavailable_body": "Đồng bộ đám mây yêu cầu Dịch vụ Google Play và không khả dụng trong bản F-Droid.", "sync_fdroid_unavailable_title": "Không khả dụng trên F-Droid", "settings_sync_brief_description": "Đồng bộ đám mây cho phép bạn đồng bộ thông tin đã chọn trên tất cả thiết bị. Thông tin không được bật sẽ chỉ ở trên thiết bị này."}, "apple": {"settings_sync_off_notifications_warning": "Đồng bộ giữa các thiết bị đang tắt. Thiết bị Apple dựa vào máy chủ TigerDuck để nhận thông báo. Nhấn để biết thêm.", "settings_sync_brief_description_ios": "Đồng bộ đám mây cho phép bạn nhận thông báo đẩy và đồng bộ thông tin. Thông tin không được bật vẫn được gửi đến máy chủ cho thông báo đẩy."}},
    "yue-HK": {"shared": {"onboarding_sync_not_shared_password": "密碼永遠唔會上傳", "onboarding_sync_shared_assignments": "功課資料", "onboarding_sync_shared_courses": "課程資料", "onboarding_sync_shared_moodle_token": "Moodle token（加密上傳）", "onboarding_sync_shared_student_id": "學號", "sync_conflict_message": "本機同伺服器之間有啲項目唔同：", "sync_conflict_status_completed": "已完成", "sync_conflict_status_ignored": "已忽略", "sync_conflict_status_none": "冇", "sync_conflict_title": "同步衝突", "sync_conflict_use_local": "用本機", "sync_conflict_use_server": "用伺服器", "sync_fdroid_unavailable_body": "雲端同步需要 Google Play 服務，F-Droid 版本唔支援。", "sync_fdroid_unavailable_title": "F-Droid 唔支援", "settings_sync_brief_description": "雲端同步可以將你揀嘅資料同步到所有已開啟雲端同步嘅裝置。未啟用同步嘅資料只會留喺呢部裝置。"}, "apple": {"settings_sync_off_notifications_warning": "跨裝置同步已關閉。Apple 裝置需要 TigerDuck 伺服器先收到通知。撳嚟了解更多。", "settings_sync_brief_description_ios": "雲端同步可以接收推播通知同埋同步資料。未啟用同步嘅資料都會傳去伺服器用嚟推播通知。"}},
}
# fmt: on


def apply():
    en = json.load(open(os.path.join(SOURCE_DIR, "en.json")))
    updated = 0
    for lang, sections in sorted(TRANSLATIONS.items()):
        path = os.path.join(SOURCE_DIR, f"{lang}.json")
        if not os.path.exists(path):
            print(f"  SKIP {lang}: file not found")
            continue
        data = json.load(open(path))
        changed = False
        for section, keys in sections.items():
            if section not in data:
                data[section] = {}
            for key, value in keys.items():
                en_value = en.get(section, {}).get(key)
                current = data[section].get(key)
                if current is None or current == en_value:
                    data[section][key] = value
                    changed = True
        if changed:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=4)
                f.write("\n")
            updated += 1
            print(f"  OK {lang}")
    print(f"\nUpdated {updated} locale files")


if __name__ == "__main__":
    apply()
