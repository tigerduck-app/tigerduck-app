#!/usr/bin/env python3
"""
Translate sync-related keys for all locales that currently fall back to EN.

Keys handled:
  shared: settings_learn_more_backend
  apple:  onboarding_sync_disabled_note, onboarding_sync_subtitle,
          settings_sync_brief_description, settings_sync_data_section,
          settings_sync_disabled_note, settings_sync_toggle_label,
          settings_notifications_disabled_warning,
          settings_sync_status_off, settings_sync_status_on
"""
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = os.path.join(SCRIPT_DIR, "..", "app-translation", "source")

# English reference values — only update if current value matches these
EN_SHARED = {
    "settings_learn_more_backend": "Learn more about the TigerDuck Backend",
}
EN_APPLE = {
    "onboarding_sync_disabled_note": "When sync is off, all data stays on this device only. Push notifications still work locally.",
    "onboarding_sync_subtitle": "When enabled, TigerDuck syncs timetable edits and assignment states across your devices via the TigerDuck server.",
    "settings_sync_brief_description": "Sync timetable edits and assignment states across your devices.",
    "settings_sync_data_section": "Data shared with the server",
    "settings_sync_disabled_note": "When sync is off, all data stays on this device only.",
    "settings_sync_toggle_label": "Enable cross-device sync",
    "settings_notifications_disabled_warning": "Notifications are off. Tap to open System Settings.",
    "settings_sync_status_off": "Off",
    "settings_sync_status_on": "On",
}

# fmt: off
TRANSLATIONS = {
    "ar": {
        "shared": {
            "settings_learn_more_backend": "تعرّف على المزيد حول خادم TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "عند إيقاف المزامنة، تبقى جميع البيانات على هذا الجهاز فقط. تعمل الإشعارات الفورية محليًا.",
            "onboarding_sync_subtitle": "عند التفعيل، يقوم TigerDuck بمزامنة تعديلات الجدول وحالات الواجبات عبر أجهزتك من خلال خادم TigerDuck.",
            "settings_sync_brief_description": "مزامنة تعديلات الجدول وحالات الواجبات عبر أجهزتك.",
            "settings_sync_data_section": "البيانات المشتركة مع الخادم",
            "settings_sync_disabled_note": "عند إيقاف المزامنة، تبقى جميع البيانات على هذا الجهاز فقط.",
            "settings_sync_toggle_label": "تفعيل المزامنة عبر الأجهزة",
        },
    },
    "bg": {
        "shared": {
            "settings_learn_more_backend": "Научете повече за сървъра на TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Когато синхронизацията е изключена, всички данни остават само на това устройство. Push известията работят локално.",
            "onboarding_sync_subtitle": "Когато е включена, TigerDuck синхронизира редакциите на разписанието и състоянията на задачите между вашите устройства чрез сървъра на TigerDuck.",
            "settings_sync_brief_description": "Синхронизиране на редакции на разписанието и състояния на задачи между вашите устройства.",
            "settings_sync_data_section": "Данни, споделени със сървъра",
            "settings_sync_disabled_note": "Когато синхронизацията е изключена, всички данни остават само на това устройство.",
            "settings_sync_toggle_label": "Включване на синхронизация между устройства",
            "settings_notifications_disabled_warning": "Известията са изключени. Докоснете, за да отворите Системни настройки.",
            "settings_sync_status_off": "Изкл.",
            "settings_sync_status_on": "Вкл.",
        },
    },
    "bn": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck ব্যাকএন্ড সম্পর্কে আরও জানুন",
        },
        "apple": {
            "onboarding_sync_disabled_note": "সিঙ্ক বন্ধ থাকলে সব ডেটা শুধুমাত্র এই ডিভাইসে থাকে। পুশ নোটিফিকেশন স্থানীয়ভাবে কাজ করে।",
            "onboarding_sync_subtitle": "সক্রিয় থাকলে, TigerDuck আপনার ডিভাইসগুলোর মধ্যে টাইমটেবিল সম্পাদনা এবং অ্যাসাইনমেন্টের অবস্থা TigerDuck সার্ভারের মাধ্যমে সিঙ্ক করে।",
            "settings_sync_brief_description": "আপনার ডিভাইসগুলোর মধ্যে টাইমটেবিল সম্পাদনা ও অ্যাসাইনমেন্টের অবস্থা সিঙ্ক করুন।",
            "settings_sync_data_section": "সার্ভারের সাথে শেয়ার করা ডেটা",
            "settings_sync_disabled_note": "সিঙ্ক বন্ধ থাকলে সব ডেটা শুধুমাত্র এই ডিভাইসে থাকে।",
            "settings_sync_toggle_label": "ক্রস-ডিভাইস সিঙ্ক সক্রিয় করুন",
            "settings_notifications_disabled_warning": "নোটিফিকেশন বন্ধ আছে। সিস্টেম সেটিংস খুলতে ট্যাপ করুন।",
            "settings_sync_status_off": "বন্ধ",
            "settings_sync_status_on": "চালু",
        },
    },
    "ca": {
        "shared": {
            "settings_learn_more_backend": "Més informació sobre el servidor de TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Quan la sincronització és desactivada, totes les dades es queden només en aquest dispositiu. Les notificacions push funcionen localment.",
            "onboarding_sync_subtitle": "Quan està activada, TigerDuck sincronitza les edicions de l'horari i els estats dels treballs entre els teus dispositius a través del servidor de TigerDuck.",
            "settings_sync_brief_description": "Sincronitza les edicions de l'horari i els estats dels treballs entre els teus dispositius.",
            "settings_sync_data_section": "Dades compartides amb el servidor",
            "settings_sync_disabled_note": "Quan la sincronització és desactivada, totes les dades es queden només en aquest dispositiu.",
            "settings_sync_toggle_label": "Activar la sincronització entre dispositius",
            "settings_notifications_disabled_warning": "Les notificacions estan desactivades. Toca per obrir Configuració del sistema.",
            "settings_sync_status_off": "Desactivat",
            "settings_sync_status_on": "Activat",
        },
    },
    "cs": {
        "shared": {
            "settings_learn_more_backend": "Více informací o serveru TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Když je synchronizace vypnutá, všechna data zůstávají pouze na tomto zařízení. Push notifikace fungují lokálně.",
            "onboarding_sync_subtitle": "Pokud je zapnutá, TigerDuck synchronizuje úpravy rozvrhu a stavy úkolů mezi vašimi zařízeními prostřednictvím serveru TigerDuck.",
            "settings_sync_brief_description": "Synchronizujte úpravy rozvrhu a stavy úkolů mezi vašimi zařízeními.",
            "settings_sync_data_section": "Data sdílená se serverem",
            "settings_sync_disabled_note": "Když je synchronizace vypnutá, všechna data zůstávají pouze na tomto zařízení.",
            "settings_sync_toggle_label": "Zapnout synchronizaci mezi zařízeními",
            "settings_notifications_disabled_warning": "Oznámení jsou vypnutá. Klepněte pro otevření Nastavení systému.",
        },
    },
    "da": {
        "shared": {
            "settings_learn_more_backend": "Læs mere om TigerDuck-serveren",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Når synkronisering er slået fra, forbliver alle data kun på denne enhed. Push-notifikationer fungerer lokalt.",
            "onboarding_sync_subtitle": "Når det er aktiveret, synkroniserer TigerDuck skemaændringer og opgavestatus på tværs af dine enheder via TigerDuck-serveren.",
            "settings_sync_brief_description": "Synkroniser skemaændringer og opgavestatus på tværs af dine enheder.",
            "settings_sync_data_section": "Data delt med serveren",
            "settings_sync_disabled_note": "Når synkronisering er slået fra, forbliver alle data kun på denne enhed.",
            "settings_sync_toggle_label": "Aktiver synkronisering på tværs af enheder",
            "settings_notifications_disabled_warning": "Notifikationer er slået fra. Tryk for at åbne Systemindstillinger.",
        },
    },
    "de": {
        "shared": {
            "settings_learn_more_backend": "Mehr über den TigerDuck-Server erfahren",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Wenn die Synchronisierung deaktiviert ist, verbleiben alle Daten nur auf diesem Gerät. Push-Benachrichtigungen funktionieren lokal.",
            "onboarding_sync_subtitle": "Wenn aktiviert, synchronisiert TigerDuck Stundenplan-Änderungen und Aufgabenstatus über deine Geräte hinweg über den TigerDuck-Server.",
            "settings_sync_brief_description": "Synchronisiere Stundenplan-Änderungen und Aufgabenstatus über deine Geräte hinweg.",
            "settings_sync_data_section": "Mit dem Server geteilte Daten",
            "settings_sync_disabled_note": "Wenn die Synchronisierung deaktiviert ist, verbleiben alle Daten nur auf diesem Gerät.",
            "settings_sync_toggle_label": "Geräteübergreifende Synchronisierung aktivieren",
        },
    },
    "el": {
        "shared": {
            "settings_learn_more_backend": "Μάθετε περισσότερα για τον διακομιστή TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Όταν ο συγχρονισμός είναι απενεργοποιημένος, όλα τα δεδομένα παραμένουν μόνο σε αυτή τη συσκευή. Οι ειδοποιήσεις push λειτουργούν τοπικά.",
            "onboarding_sync_subtitle": "Όταν είναι ενεργοποιημένη, η εφαρμογή TigerDuck συγχρονίζει τις αλλαγές προγράμματος και τις καταστάσεις εργασιών μεταξύ των συσκευών σας μέσω του διακομιστή TigerDuck.",
            "settings_sync_brief_description": "Συγχρονισμός αλλαγών προγράμματος και καταστάσεων εργασιών μεταξύ των συσκευών σας.",
            "settings_sync_data_section": "Δεδομένα που μοιράζονται με τον διακομιστή",
            "settings_sync_disabled_note": "Όταν ο συγχρονισμός είναι απενεργοποιημένος, όλα τα δεδομένα παραμένουν μόνο σε αυτή τη συσκευή.",
            "settings_sync_toggle_label": "Ενεργοποίηση συγχρονισμού μεταξύ συσκευών",
            "settings_notifications_disabled_warning": "Οι ειδοποιήσεις είναι απενεργοποιημένες. Πατήστε για να ανοίξετε τις Ρυθμίσεις συστήματος.",
            "settings_sync_status_off": "Ανενεργό",
            "settings_sync_status_on": "Ενεργό",
        },
    },
    "en-GB": {
        "shared": {
            "settings_learn_more_backend": "Learn more about the TigerDuck Backend",
        },
        "apple": {
            "onboarding_sync_disabled_note": "When sync is off, all data stays on this device only. Push notifications still work locally.",
            "onboarding_sync_subtitle": "When enabled, TigerDuck syncs timetable edits and assignment states across your devices via the TigerDuck server.",
            "settings_sync_brief_description": "Sync timetable edits and assignment states across your devices.",
            "settings_sync_data_section": "Data shared with the server",
            "settings_sync_disabled_note": "When sync is off, all data stays on this device only.",
            "settings_sync_toggle_label": "Enable cross-device sync",
            "settings_notifications_disabled_warning": "Notifications are off. Tap to open System Settings.",
            "settings_sync_status_off": "Off",
            "settings_sync_status_on": "On",
        },
    },
    "es": {
        "shared": {
            "settings_learn_more_backend": "Más información sobre el servidor de TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Cuando la sincronización está desactivada, todos los datos permanecen solo en este dispositivo. Las notificaciones push funcionan localmente.",
            "onboarding_sync_subtitle": "Cuando está activada, TigerDuck sincroniza las ediciones del horario y los estados de las tareas entre tus dispositivos a través del servidor de TigerDuck.",
            "settings_sync_brief_description": "Sincroniza las ediciones del horario y los estados de las tareas entre tus dispositivos.",
            "settings_sync_data_section": "Datos compartidos con el servidor",
            "settings_sync_disabled_note": "Cuando la sincronización está desactivada, todos los datos permanecen solo en este dispositivo.",
            "settings_sync_toggle_label": "Activar sincronización entre dispositivos",
        },
    },
    "et": {
        "shared": {
            "settings_learn_more_backend": "Lisateave TigerDucki serveri kohta",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kui sünkroonimine on välja lülitatud, jäävad kõik andmed ainult sellesse seadmesse. Tõuketeavitused töötavad kohalikult.",
            "onboarding_sync_subtitle": "Kui see on sisse lülitatud, sünkroonib TigerDuck tunniplaani muudatused ja ülesannete olekud teie seadmete vahel TigerDucki serveri kaudu.",
            "settings_sync_brief_description": "Sünkroonige tunniplaani muudatused ja ülesannete olekud oma seadmete vahel.",
            "settings_sync_data_section": "Serveriga jagatud andmed",
            "settings_sync_disabled_note": "Kui sünkroonimine on välja lülitatud, jäävad kõik andmed ainult sellesse seadmesse.",
            "settings_sync_toggle_label": "Luba seadmetevaheline sünkroonimine",
            "settings_notifications_disabled_warning": "Teavitused on välja lülitatud. Puudutage süsteemiseadete avamiseks.",
            "settings_sync_status_off": "Väljas",
            "settings_sync_status_on": "Sees",
        },
    },
    "fa": {
        "shared": {
            "settings_learn_more_backend": "اطلاعات بیشتر درباره سرور TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "وقتی همگام‌سازی خاموش است، همه داده‌ها فقط در این دستگاه باقی می‌مانند. اعلان‌های فوری به صورت محلی کار می‌کنند.",
            "onboarding_sync_subtitle": "وقتی فعال باشد، TigerDuck ویرایش‌های برنامه و وضعیت تکالیف را از طریق سرور TigerDuck بین دستگاه‌های شما همگام‌سازی می‌کند.",
            "settings_sync_brief_description": "همگام‌سازی ویرایش‌های برنامه و وضعیت تکالیف بین دستگاه‌های شما.",
            "settings_sync_data_section": "داده‌های به اشتراک گذاشته شده با سرور",
            "settings_sync_disabled_note": "وقتی همگام‌سازی خاموش است، همه داده‌ها فقط در این دستگاه باقی می‌مانند.",
            "settings_sync_toggle_label": "فعال‌سازی همگام‌سازی بین دستگاه‌ها",
            "settings_notifications_disabled_warning": "اعلان‌ها خاموش هستند. برای باز کردن تنظیمات سیستم ضربه بزنید.",
        },
    },
    "fi": {
        "shared": {
            "settings_learn_more_backend": "Lue lisää TigerDuck-palvelimesta",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kun synkronointi on pois päältä, kaikki tiedot pysyvät vain tässä laitteessa. Push-ilmoitukset toimivat paikallisesti.",
            "onboarding_sync_subtitle": "Kun tämä on käytössä, TigerDuck synkronoi lukujärjestyksen muokkaukset ja tehtävien tilat laitteidesi välillä TigerDuck-palvelimen kautta.",
            "settings_sync_brief_description": "Synkronoi lukujärjestyksen muokkaukset ja tehtävien tilat laitteidesi välillä.",
            "settings_sync_data_section": "Palvelimen kanssa jaetut tiedot",
            "settings_sync_disabled_note": "Kun synkronointi on pois päältä, kaikki tiedot pysyvät vain tässä laitteessa.",
            "settings_sync_toggle_label": "Ota laitteiden välinen synkronointi käyttöön",
            "settings_notifications_disabled_warning": "Ilmoitukset ovat pois päältä. Napauta avataksesi Järjestelmäasetukset.",
        },
    },
    "fil": {
        "shared": {
            "settings_learn_more_backend": "Alamin pa ang tungkol sa TigerDuck Backend",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kapag naka-off ang sync, ang lahat ng data ay nananatili sa device na ito lamang. Gumagana pa rin nang lokal ang push notification.",
            "onboarding_sync_subtitle": "Kapag naka-enable, sini-sync ng TigerDuck ang mga pagbabago sa timetable at estado ng mga assignment sa iyong mga device sa pamamagitan ng TigerDuck server.",
            "settings_sync_brief_description": "I-sync ang mga pagbabago sa timetable at estado ng mga assignment sa iyong mga device.",
            "settings_sync_data_section": "Data na ibinabahagi sa server",
            "settings_sync_disabled_note": "Kapag naka-off ang sync, ang lahat ng data ay nananatili sa device na ito lamang.",
            "settings_sync_toggle_label": "I-enable ang cross-device sync",
            "settings_notifications_disabled_warning": "Naka-off ang mga notification. I-tap para buksan ang System Settings.",
            "settings_sync_status_off": "Naka-off",
            "settings_sync_status_on": "Naka-on",
        },
    },
    "fr": {
        "shared": {
            "settings_learn_more_backend": "En savoir plus sur le serveur TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Quand la synchronisation est désactivée, toutes les données restent uniquement sur cet appareil. Les notifications push fonctionnent localement.",
            "onboarding_sync_subtitle": "Lorsqu'elle est activée, TigerDuck synchronise les modifications d'emploi du temps et les états des devoirs entre vos appareils via le serveur TigerDuck.",
            "settings_sync_brief_description": "Synchronisez les modifications d'emploi du temps et les états des devoirs entre vos appareils.",
            "settings_sync_data_section": "Données partagées avec le serveur",
            "settings_sync_disabled_note": "Quand la synchronisation est désactivée, toutes les données restent uniquement sur cet appareil.",
            "settings_sync_toggle_label": "Activer la synchronisation multi-appareils",
        },
    },
    "gu": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck બેકએન્ડ વિશે વધુ જાણો",
        },
        "apple": {
            "onboarding_sync_disabled_note": "જ્યારે સિંક બંધ હોય, ત્યારે બધો ડેટા ફક્ત આ ડિવાઇસ પર જ રહે છે. પુશ નોટિફિકેશન સ્થાનિક રીતે કામ કરે છે.",
            "onboarding_sync_subtitle": "સક્ષમ હોય ત્યારે, TigerDuck તમારા ઉપકરણો વચ્ચે ટાઇમટેબલ ફેરફારો અને અસાઇનમેન્ટ સ્થિતિઓ TigerDuck સર્વર દ્વારા સિંક કરે છે.",
            "settings_sync_brief_description": "તમારા ઉપકરણો વચ્ચે ટાઇમટેબલ ફેરફારો અને અસાઇનમેન્ટ સ્થિતિઓ સિંક કરો.",
            "settings_sync_data_section": "સર્વર સાથે શેર કરેલો ડેટા",
            "settings_sync_disabled_note": "જ્યારે સિંક બંધ હોય, ત્યારે બધો ડેટા ફક્ત આ ડિવાઇસ પર જ રહે છે.",
            "settings_sync_toggle_label": "ક્રોસ-ડિવાઇસ સિંક સક્ષમ કરો",
            "settings_notifications_disabled_warning": "નોટિફિકેશન બંધ છે. સિસ્ટમ સેટિંગ્સ ખોલવા ટેપ કરો.",
            "settings_sync_status_off": "બંધ",
            "settings_sync_status_on": "ચાલુ",
        },
    },
    "he": {
        "shared": {
            "settings_learn_more_backend": "למידע נוסף על שרת TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "כאשר הסנכרון כבוי, כל הנתונים נשארים במכשיר זה בלבד. התראות פוש פועלות מקומית.",
            "onboarding_sync_subtitle": "כאשר מופעל, TigerDuck מסנכרן עריכות מערכת שעות ומצבי מטלות בין המכשירים שלך דרך שרת TigerDuck.",
            "settings_sync_brief_description": "סנכרן עריכות מערכת שעות ומצבי מטלות בין המכשירים שלך.",
            "settings_sync_data_section": "נתונים המשותפים עם השרת",
            "settings_sync_disabled_note": "כאשר הסנכרון כבוי, כל הנתונים נשארים במכשיר זה בלבד.",
            "settings_sync_toggle_label": "הפעל סנכרון בין מכשירים",
            "settings_notifications_disabled_warning": "ההתראות כבויות. הקש כדי לפתוח את הגדרות המערכת.",
        },
    },
    "hi": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck बैकएंड के बारे में अधिक जानें",
        },
        "apple": {
            "onboarding_sync_disabled_note": "जब सिंक बंद हो, तो सभी डेटा केवल इस डिवाइस पर ही रहता है। पुश नोटिफिकेशन स्थानीय रूप से काम करते हैं।",
            "onboarding_sync_subtitle": "सक्षम होने पर, TigerDuck आपके डिवाइस के बीच टाइमटेबल संपादन और असाइनमेंट स्थितियों को TigerDuck सर्वर के माध्यम से सिंक करता है।",
            "settings_sync_brief_description": "अपने डिवाइस के बीच टाइमटेबल संपादन और असाइनमेंट स्थितियाँ सिंक करें।",
            "settings_sync_data_section": "सर्वर के साथ साझा किया गया डेटा",
            "settings_sync_disabled_note": "जब सिंक बंद हो, तो सभी डेटा केवल इस डिवाइस पर ही रहता है।",
            "settings_sync_toggle_label": "क्रॉस-डिवाइस सिंक सक्षम करें",
        },
    },
    "hr": {
        "shared": {
            "settings_learn_more_backend": "Saznajte više o TigerDuck poslužitelju",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kad je sinkronizacija isključena, svi podaci ostaju samo na ovom uređaju. Push obavijesti rade lokalno.",
            "onboarding_sync_subtitle": "Kad je uključena, TigerDuck sinkronizira uređivanja rasporeda i stanja zadataka između vaših uređaja putem TigerDuck poslužitelja.",
            "settings_sync_brief_description": "Sinkronizirajte uređivanja rasporeda i stanja zadataka između vaših uređaja.",
            "settings_sync_data_section": "Podaci dijeljeni s poslužiteljem",
            "settings_sync_disabled_note": "Kad je sinkronizacija isključena, svi podaci ostaju samo na ovom uređaju.",
            "settings_sync_toggle_label": "Uključi sinkronizaciju između uređaja",
            "settings_notifications_disabled_warning": "Obavijesti su isključene. Dodirnite za otvaranje Postavki sustava.",
            "settings_sync_status_off": "Isključeno",
            "settings_sync_status_on": "Uključeno",
        },
    },
    "hu": {
        "shared": {
            "settings_learn_more_backend": "Tudjon meg többet a TigerDuck szerverről",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Ha a szinkronizálás ki van kapcsolva, minden adat csak ezen az eszközön marad. A push értesítések helyben működnek.",
            "onboarding_sync_subtitle": "Ha engedélyezve van, a TigerDuck szinkronizálja az órarend-módosításokat és a feladatok állapotát az eszközei között a TigerDuck szerveren keresztül.",
            "settings_sync_brief_description": "Szinkronizálja az órarend-módosításokat és a feladatok állapotát az eszközei között.",
            "settings_sync_data_section": "A szerverrel megosztott adatok",
            "settings_sync_disabled_note": "Ha a szinkronizálás ki van kapcsolva, minden adat csak ezen az eszközön marad.",
            "settings_sync_toggle_label": "Eszközök közötti szinkronizálás engedélyezése",
            "settings_notifications_disabled_warning": "Az értesítések ki vannak kapcsolva. Koppintson a Rendszerbeállítások megnyitásához.",
        },
    },
    "id": {
        "shared": {
            "settings_learn_more_backend": "Pelajari lebih lanjut tentang Server TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Saat sinkronisasi mati, semua data hanya tersimpan di perangkat ini. Notifikasi push tetap berfungsi secara lokal.",
            "onboarding_sync_subtitle": "Saat diaktifkan, TigerDuck menyinkronkan perubahan jadwal dan status tugas di seluruh perangkat Anda melalui server TigerDuck.",
            "settings_sync_brief_description": "Sinkronkan perubahan jadwal dan status tugas di seluruh perangkat Anda.",
            "settings_sync_data_section": "Data yang dibagikan dengan server",
            "settings_sync_disabled_note": "Saat sinkronisasi mati, semua data hanya tersimpan di perangkat ini.",
            "settings_sync_toggle_label": "Aktifkan sinkronisasi lintas perangkat",
        },
    },
    "is": {
        "shared": {
            "settings_learn_more_backend": "Frekari upplýsingar um TigerDuck-þjóninn",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Þegar samstilling er slökkt eru öll gögn aðeins á þessu tæki. Push-tilkynningar virka staðbundið.",
            "onboarding_sync_subtitle": "Þegar virkt, samstillir TigerDuck breytingar á stundaskrá og stöður verkefna milli tækja þinna í gegnum TigerDuck-þjóninn.",
            "settings_sync_brief_description": "Samstilltu breytingar á stundaskrá og stöður verkefna milli tækja þinna.",
            "settings_sync_data_section": "Gögn deild með þjóninum",
            "settings_sync_disabled_note": "Þegar samstilling er slökkt eru öll gögn aðeins á þessu tæki.",
            "settings_sync_toggle_label": "Virkja samstillingu milli tækja",
            "settings_notifications_disabled_warning": "Tilkynningar eru slökktar. Ýttu til að opna Kerfisstillingar.",
            "settings_sync_status_off": "Slökkt",
            "settings_sync_status_on": "Kveikt",
        },
    },
    "it": {
        "shared": {
            "settings_learn_more_backend": "Scopri di più sul server TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Quando la sincronizzazione è disattivata, tutti i dati restano solo su questo dispositivo. Le notifiche push funzionano localmente.",
            "onboarding_sync_subtitle": "Quando attivata, TigerDuck sincronizza le modifiche all'orario e gli stati dei compiti tra i tuoi dispositivi tramite il server TigerDuck.",
            "settings_sync_brief_description": "Sincronizza le modifiche all'orario e gli stati dei compiti tra i tuoi dispositivi.",
            "settings_sync_data_section": "Dati condivisi con il server",
            "settings_sync_disabled_note": "Quando la sincronizzazione è disattivata, tutti i dati restano solo su questo dispositivo.",
            "settings_sync_toggle_label": "Attiva la sincronizzazione tra dispositivi",
        },
    },
    "ja": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck バックエンドについて詳しく見る",
        },
        "apple": {
            "onboarding_sync_disabled_note": "同期がオフの場合、すべてのデータはこのデバイスのみに保存されます。プッシュ通知はローカルで動作します。",
            "onboarding_sync_subtitle": "有効にすると、TigerDuck は TigerDuck サーバーを通じて、時間割の編集や課題の状態をデバイス間で同期します。",
            "settings_sync_brief_description": "デバイス間で時間割の編集や課題の状態を同期します。",
            "settings_sync_data_section": "サーバーと共有されるデータ",
            "settings_sync_disabled_note": "同期がオフの場合、すべてのデータはこのデバイスのみに保存されます。",
            "settings_sync_toggle_label": "クロスデバイス同期を有効にする",
        },
    },
    "kk": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck серверi туралы көбірек біліңіз",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Синхрондау өшірулі кезде барлық деректер тек осы құрылғыда сақталады. Push хабарландырулар жергілікті жұмыс істейді.",
            "onboarding_sync_subtitle": "Қосылғанда, TigerDuck кесте өзгерістері мен тапсырма күйлерін TigerDuck сервері арқылы құрылғыларыңыз арасында синхрондайды.",
            "settings_sync_brief_description": "Кесте өзгерістері мен тапсырма күйлерін құрылғыларыңыз арасында синхрондаңыз.",
            "settings_sync_data_section": "Сервермен бөлісілген деректер",
            "settings_sync_disabled_note": "Синхрондау өшірулі кезде барлық деректер тек осы құрылғыда сақталады.",
            "settings_sync_toggle_label": "Құрылғылар арасындағы синхрондауды қосу",
            "settings_notifications_disabled_warning": "Хабарландырулар өшірулі. Жүйе параметрлерін ашу үшін түртіңіз.",
            "settings_sync_status_off": "Өшірулі",
            "settings_sync_status_on": "Қосулы",
        },
    },
    "kn": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck ಬ್ಯಾಕೆಂಡ್ ಬಗ್ಗೆ ಇನ್ನಷ್ಟು ತಿಳಿಯಿರಿ",
        },
        "apple": {
            "onboarding_sync_disabled_note": "ಸಿಂಕ್ ಆಫ್ ಆಗಿದ್ದಾಗ, ಎಲ್ಲಾ ಡೇಟಾ ಈ ಸಾಧನದಲ್ಲಿ ಮಾತ್ರ ಉಳಿಯುತ್ತದೆ. ಪುಶ್ ಅಧಿಸೂಚನೆಗಳು ಸ್ಥಳೀಯವಾಗಿ ಕಾರ್ಯನಿರ್ವಹಿಸುತ್ತವೆ.",
            "onboarding_sync_subtitle": "ಸಕ್ರಿಯಗೊಳಿಸಿದಾಗ, TigerDuck ನಿಮ್ಮ ಸಾಧನಗಳ ನಡುವೆ ಟೈಮ್‌ಟೇಬಲ್ ಬದಲಾವಣೆಗಳು ಮತ್ತು ಅಸೈನ್‌ಮೆಂಟ್ ಸ್ಥಿತಿಗಳನ್ನು TigerDuck ಸರ್ವರ್ ಮೂಲಕ ಸಿಂಕ್ ಮಾಡುತ್ತದೆ.",
            "settings_sync_brief_description": "ನಿಮ್ಮ ಸಾಧನಗಳ ನಡುವೆ ಟೈಮ್‌ಟೇಬಲ್ ಬದಲಾವಣೆಗಳು ಮತ್ತು ಅಸೈನ್‌ಮೆಂಟ್ ಸ್ಥಿತಿಗಳನ್ನು ಸಿಂಕ್ ಮಾಡಿ.",
            "settings_sync_data_section": "ಸರ್ವರ್‌ನೊಂದಿಗೆ ಹಂಚಿಕೊಂಡ ಡೇಟಾ",
            "settings_sync_disabled_note": "ಸಿಂಕ್ ಆಫ್ ಆಗಿದ್ದಾಗ, ಎಲ್ಲಾ ಡೇಟಾ ಈ ಸಾಧನದಲ್ಲಿ ಮಾತ್ರ ಉಳಿಯುತ್ತದೆ.",
            "settings_sync_toggle_label": "ಕ್ರಾಸ್-ಡಿವೈಸ್ ಸಿಂಕ್ ಸಕ್ರಿಯಗೊಳಿಸಿ",
            "settings_notifications_disabled_warning": "ಅಧಿಸೂಚನೆಗಳು ಆಫ್ ಆಗಿವೆ. ಸಿಸ್ಟಮ್ ಸೆಟ್ಟಿಂಗ್‌ಗಳನ್ನು ತೆರೆಯಲು ಟ್ಯಾಪ್ ಮಾಡಿ.",
            "settings_sync_status_off": "ಆಫ್",
            "settings_sync_status_on": "ಆನ್",
        },
    },
    "ko": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck 백엔드에 대해 자세히 알아보기",
        },
        "apple": {
            "onboarding_sync_disabled_note": "동기화가 꺼져 있으면 모든 데이터는 이 기기에만 저장됩니다. 푸시 알림은 로컬에서 작동합니다.",
            "onboarding_sync_subtitle": "활성화하면 TigerDuck이 TigerDuck 서버를 통해 기기 간에 시간표 편집 및 과제 상태를 동기화합니다.",
            "settings_sync_brief_description": "기기 간에 시간표 편집 및 과제 상태를 동기화합니다.",
            "settings_sync_data_section": "서버와 공유되는 데이터",
            "settings_sync_disabled_note": "동기화가 꺼져 있으면 모든 데이터는 이 기기에만 저장됩니다.",
            "settings_sync_toggle_label": "기기 간 동기화 활성화",
        },
    },
    "lt": {
        "shared": {
            "settings_learn_more_backend": "Sužinokite daugiau apie TigerDuck serverį",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kai sinchronizacija išjungta, visi duomenys lieka tik šiame įrenginyje. Push pranešimai veikia vietiniame režime.",
            "onboarding_sync_subtitle": "Kai įjungta, TigerDuck sinchronizuoja tvarkaraščio pakeitimus ir užduočių būsenas tarp jūsų įrenginių per TigerDuck serverį.",
            "settings_sync_brief_description": "Sinchronizuokite tvarkaraščio pakeitimus ir užduočių būsenas tarp savo įrenginių.",
            "settings_sync_data_section": "Duomenys, bendrinti su serveriu",
            "settings_sync_disabled_note": "Kai sinchronizacija išjungta, visi duomenys lieka tik šiame įrenginyje.",
            "settings_sync_toggle_label": "Įjungti sinchronizaciją tarp įrenginių",
            "settings_notifications_disabled_warning": "Pranešimai išjungti. Bakstelėkite, kad atidarytumėte sistemos nustatymus.",
            "settings_sync_status_off": "Išjungta",
            "settings_sync_status_on": "Įjungta",
        },
    },
    "lv": {
        "shared": {
            "settings_learn_more_backend": "Uzziniet vairāk par TigerDuck serveri",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Kad sinhronizācija ir izslēgta, visi dati paliek tikai šajā ierīcē. Push paziņojumi darbojas lokāli.",
            "onboarding_sync_subtitle": "Kad ir ieslēgta, TigerDuck sinhronizē stundu plāna izmaiņas un uzdevumu statusus starp jūsu ierīcēm, izmantojot TigerDuck serveri.",
            "settings_sync_brief_description": "Sinhronizējiet stundu plāna izmaiņas un uzdevumu statusus starp savām ierīcēm.",
            "settings_sync_data_section": "Ar serveri koplietotie dati",
            "settings_sync_disabled_note": "Kad sinhronizācija ir izslēgta, visi dati paliek tikai šajā ierīcē.",
            "settings_sync_toggle_label": "Ieslēgt sinhronizāciju starp ierīcēm",
            "settings_notifications_disabled_warning": "Paziņojumi ir izslēgti. Pieskarieties, lai atvērtu sistēmas iestatījumus.",
            "settings_sync_status_off": "Izslēgts",
            "settings_sync_status_on": "Ieslēgts",
        },
    },
    "ml": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck ബാക്കെൻഡിനെ കുറിച്ച് കൂടുതൽ അറിയുക",
        },
        "apple": {
            "onboarding_sync_disabled_note": "സിങ്ക് ഓഫ് ആയിരിക്കുമ്പോൾ, എല്ലാ ഡാറ്റയും ഈ ഉപകരണത്തിൽ മാത്രം നിലനിൽക്കും. പുഷ് അറിയിപ്പുകൾ പ്രാദേശികമായി പ്രവർത്തിക്കും.",
            "onboarding_sync_subtitle": "പ്രവർത്തനക്ഷമമാക്കുമ്പോൾ, TigerDuck സർവർ വഴി നിങ്ങളുടെ ഉപകരണങ്ങൾക്കിടയിൽ ടൈംടേബിൾ എഡിറ്റുകളും അസൈൻമെന്റ് നിലകളും TigerDuck സിങ്ക് ചെയ്യുന്നു.",
            "settings_sync_brief_description": "നിങ്ങളുടെ ഉപകരണങ്ങൾക്കിടയിൽ ടൈംടേബിൾ എഡിറ്റുകളും അസൈൻമെന്റ് നിലകളും സിങ്ക് ചെയ്യുക.",
            "settings_sync_data_section": "സെർവറുമായി പങ്കിട്ട ഡാറ്റ",
            "settings_sync_disabled_note": "സിങ്ക് ഓഫ് ആയിരിക്കുമ്പോൾ, എല്ലാ ഡാറ്റയും ഈ ഉപകരണത്തിൽ മാത്രം നിലനിൽക്കും.",
            "settings_sync_toggle_label": "ക്രോസ്-ഡിവൈസ് സിങ്ക് പ്രവർത്തനക്ഷമമാക്കുക",
            "settings_notifications_disabled_warning": "അറിയിപ്പുകൾ ഓഫ് ആണ്. സിസ്റ്റം സെറ്റിംഗ്സ് തുറക്കാൻ ടാപ്പ് ചെയ്യുക.",
            "settings_sync_status_off": "ഓഫ്",
            "settings_sync_status_on": "ഓൺ",
        },
    },
    "mr": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck बॅकएंडबद्दल अधिक जाणून घ्या",
        },
        "apple": {
            "onboarding_sync_disabled_note": "सिंक बंद असताना, सर्व डेटा फक्त या डिव्हाइसवरच राहतो. पुश सूचना स्थानिक पातळीवर कार्य करतात.",
            "onboarding_sync_subtitle": "सक्षम असताना, TigerDuck तुमच्या डिव्हाइसेसमध्ये वेळापत्रक संपादने आणि असाइनमेंट स्थिती TigerDuck सर्व्हरद्वारे सिंक करतो.",
            "settings_sync_brief_description": "तुमच्या डिव्हाइसेसमध्ये वेळापत्रक संपादने आणि असाइनमेंट स्थिती सिंक करा.",
            "settings_sync_data_section": "सर्व्हरसोबत शेअर केलेला डेटा",
            "settings_sync_disabled_note": "सिंक बंद असताना, सर्व डेटा फक्त या डिव्हाइसवरच राहतो.",
            "settings_sync_toggle_label": "क्रॉस-डिव्हाइस सिंक सक्षम करा",
            "settings_notifications_disabled_warning": "सूचना बंद आहेत. सिस्टम सेटिंग्ज उघडण्यासाठी टॅप करा.",
            "settings_sync_status_off": "बंद",
            "settings_sync_status_on": "चालू",
        },
    },
    "ms": {
        "shared": {
            "settings_learn_more_backend": "Ketahui lebih lanjut tentang Pelayan TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Apabila segerak dimatikan, semua data kekal pada peranti ini sahaja. Pemberitahuan tolak masih berfungsi secara tempatan.",
            "onboarding_sync_subtitle": "Apabila diaktifkan, TigerDuck menyegerakkan suntingan jadual waktu dan status tugasan merentas peranti anda melalui pelayan TigerDuck.",
            "settings_sync_brief_description": "Segerakkan suntingan jadual waktu dan status tugasan merentas peranti anda.",
            "settings_sync_data_section": "Data yang dikongsi dengan pelayan",
            "settings_sync_disabled_note": "Apabila segerak dimatikan, semua data kekal pada peranti ini sahaja.",
            "settings_sync_toggle_label": "Aktifkan penyegerakan merentas peranti",
            "settings_notifications_disabled_warning": "Pemberitahuan dimatikan. Ketik untuk membuka Tetapan Sistem.",
            "settings_sync_status_off": "Mati",
            "settings_sync_status_on": "Hidup",
        },
    },
    "nl": {
        "shared": {
            "settings_learn_more_backend": "Meer informatie over de TigerDuck-server",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Wanneer synchronisatie uit staat, blijven alle gegevens alleen op dit apparaat. Pushmeldingen werken lokaal.",
            "onboarding_sync_subtitle": "Wanneer ingeschakeld, synchroniseert TigerDuck roosterbewerkingen en opdrachtstatussen tussen je apparaten via de TigerDuck-server.",
            "settings_sync_brief_description": "Synchroniseer roosterbewerkingen en opdrachtstatussen tussen je apparaten.",
            "settings_sync_data_section": "Gegevens gedeeld met de server",
            "settings_sync_disabled_note": "Wanneer synchronisatie uit staat, blijven alle gegevens alleen op dit apparaat.",
            "settings_sync_toggle_label": "Synchronisatie tussen apparaten inschakelen",
            "settings_notifications_disabled_warning": "Meldingen staan uit. Tik om Systeeminstellingen te openen.",
            "settings_sync_status_off": "Uit",
            "settings_sync_status_on": "Aan",
        },
    },
    "no": {
        "shared": {
            "settings_learn_more_backend": "Les mer om TigerDuck-serveren",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Når synkronisering er av, forblir alle data kun på denne enheten. Push-varsler fungerer lokalt.",
            "onboarding_sync_subtitle": "Når aktivert, synkroniserer TigerDuck timeplanendringer og oppgavestatuser på tvers av enhetene dine via TigerDuck-serveren.",
            "settings_sync_brief_description": "Synkroniser timeplanendringer og oppgavestatuser på tvers av enhetene dine.",
            "settings_sync_data_section": "Data delt med serveren",
            "settings_sync_disabled_note": "Når synkronisering er av, forblir alle data kun på denne enheten.",
            "settings_sync_toggle_label": "Aktiver synkronisering på tvers av enheter",
            "settings_notifications_disabled_warning": "Varsler er av. Trykk for å åpne Systeminnstillinger.",
            "settings_sync_status_off": "Av",
            "settings_sync_status_on": "På",
        },
    },
    "pa": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck ਬੈਕਐਂਡ ਬਾਰੇ ਹੋਰ ਜਾਣੋ",
        },
        "apple": {
            "onboarding_sync_disabled_note": "ਜਦੋਂ ਸਿੰਕ ਬੰਦ ਹੁੰਦਾ ਹੈ, ਸਾਰਾ ਡੇਟਾ ਸਿਰਫ਼ ਇਸ ਡਿਵਾਈਸ 'ਤੇ ਰਹਿੰਦਾ ਹੈ। ਪੁਸ਼ ਸੂਚਨਾਵਾਂ ਸਥਾਨਕ ਤੌਰ 'ਤੇ ਕੰਮ ਕਰਦੀਆਂ ਹਨ।",
            "onboarding_sync_subtitle": "ਸਮਰੱਥ ਹੋਣ 'ਤੇ, TigerDuck ਤੁਹਾਡੇ ਡਿਵਾਈਸਾਂ ਵਿਚਕਾਰ ਟਾਈਮਟੇਬਲ ਸੰਪਾਦਨ ਅਤੇ ਅਸਾਈਨਮੈਂਟ ਸਥਿਤੀਆਂ ਨੂੰ TigerDuck ਸਰਵਰ ਰਾਹੀਂ ਸਿੰਕ ਕਰਦਾ ਹੈ।",
            "settings_sync_brief_description": "ਆਪਣੇ ਡਿਵਾਈਸਾਂ ਵਿਚਕਾਰ ਟਾਈਮਟੇਬਲ ਸੰਪਾਦਨ ਅਤੇ ਅਸਾਈਨਮੈਂਟ ਸਥਿਤੀਆਂ ਸਿੰਕ ਕਰੋ।",
            "settings_sync_data_section": "ਸਰਵਰ ਨਾਲ ਸਾਂਝਾ ਕੀਤਾ ਡੇਟਾ",
            "settings_sync_disabled_note": "ਜਦੋਂ ਸਿੰਕ ਬੰਦ ਹੁੰਦਾ ਹੈ, ਸਾਰਾ ਡੇਟਾ ਸਿਰਫ਼ ਇਸ ਡਿਵਾਈਸ 'ਤੇ ਰਹਿੰਦਾ ਹੈ।",
            "settings_sync_toggle_label": "ਕ੍ਰਾਸ-ਡਿਵਾਈਸ ਸਿੰਕ ਸਮਰੱਥ ਕਰੋ",
            "settings_notifications_disabled_warning": "ਸੂਚਨਾਵਾਂ ਬੰਦ ਹਨ। ਸਿਸਟਮ ਸੈਟਿੰਗਾਂ ਖੋਲ੍ਹਣ ਲਈ ਟੈਪ ਕਰੋ।",
            "settings_sync_status_off": "ਬੰਦ",
            "settings_sync_status_on": "ਚਾਲੂ",
        },
    },
    "pl": {
        "shared": {
            "settings_learn_more_backend": "Dowiedz się więcej o serwerze TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Gdy synchronizacja jest wyłączona, wszystkie dane pozostają tylko na tym urządzeniu. Powiadomienia push działają lokalnie.",
            "onboarding_sync_subtitle": "Po włączeniu TigerDuck synchronizuje edycje planu zajęć i stany zadań między Twoimi urządzeniami za pośrednictwem serwera TigerDuck.",
            "settings_sync_brief_description": "Synchronizuj edycje planu zajęć i stany zadań między swoimi urządzeniami.",
            "settings_sync_data_section": "Dane udostępniane serwerowi",
            "settings_sync_disabled_note": "Gdy synchronizacja jest wyłączona, wszystkie dane pozostają tylko na tym urządzeniu.",
            "settings_sync_toggle_label": "Włącz synchronizację między urządzeniami",
            "settings_notifications_disabled_warning": "Powiadomienia są wyłączone. Stuknij, aby otworzyć Ustawienia systemowe.",
        },
    },
    "pt-BR": {
        "shared": {
            "settings_learn_more_backend": "Saiba mais sobre o servidor TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Quando a sincronização está desativada, todos os dados ficam apenas neste dispositivo. As notificações push funcionam localmente.",
            "onboarding_sync_subtitle": "Quando ativado, o TigerDuck sincroniza edições de horário e estados de tarefas entre seus dispositivos através do servidor TigerDuck.",
            "settings_sync_brief_description": "Sincronize edições de horário e estados de tarefas entre seus dispositivos.",
            "settings_sync_data_section": "Dados compartilhados com o servidor",
            "settings_sync_disabled_note": "Quando a sincronização está desativada, todos os dados ficam apenas neste dispositivo.",
            "settings_sync_toggle_label": "Ativar sincronização entre dispositivos",
        },
    },
    "pt-PT": {
        "shared": {
            "settings_learn_more_backend": "Saiba mais sobre o servidor TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Quando a sincronização está desativada, todos os dados ficam apenas neste dispositivo. As notificações push funcionam localmente.",
            "onboarding_sync_subtitle": "Quando ativada, o TigerDuck sincroniza edições de horário e estados de tarefas entre os seus dispositivos através do servidor TigerDuck.",
            "settings_sync_brief_description": "Sincronize edições de horário e estados de tarefas entre os seus dispositivos.",
            "settings_sync_data_section": "Dados partilhados com o servidor",
            "settings_sync_disabled_note": "Quando a sincronização está desativada, todos os dados ficam apenas neste dispositivo.",
            "settings_sync_toggle_label": "Ativar sincronização entre dispositivos",
            "settings_notifications_disabled_warning": "As notificações estão desativadas. Toque para abrir as Definições do sistema.",
        },
    },
    "ro": {
        "shared": {
            "settings_learn_more_backend": "Aflați mai multe despre serverul TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Când sincronizarea este dezactivată, toate datele rămân doar pe acest dispozitiv. Notificările push funcționează local.",
            "onboarding_sync_subtitle": "Când este activată, TigerDuck sincronizează editările orarului și stările temelor între dispozitivele tale prin serverul TigerDuck.",
            "settings_sync_brief_description": "Sincronizează editările orarului și stările temelor între dispozitivele tale.",
            "settings_sync_data_section": "Date partajate cu serverul",
            "settings_sync_disabled_note": "Când sincronizarea este dezactivată, toate datele rămân doar pe acest dispozitiv.",
            "settings_sync_toggle_label": "Activează sincronizarea între dispozitive",
            "settings_notifications_disabled_warning": "Notificările sunt dezactivate. Atinge pentru a deschide Setările sistemului.",
        },
    },
    "ru": {
        "shared": {
            "settings_learn_more_backend": "Узнайте больше о сервере TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Когда синхронизация отключена, все данные остаются только на этом устройстве. Push-уведомления работают локально.",
            "onboarding_sync_subtitle": "При включении TigerDuck синхронизирует изменения расписания и статусы заданий между вашими устройствами через сервер TigerDuck.",
            "settings_sync_brief_description": "Синхронизируйте изменения расписания и статусы заданий между вашими устройствами.",
            "settings_sync_data_section": "Данные, передаваемые серверу",
            "settings_sync_disabled_note": "Когда синхронизация отключена, все данные остаются только на этом устройстве.",
            "settings_sync_toggle_label": "Включить синхронизацию между устройствами",
        },
    },
    "sk": {
        "shared": {
            "settings_learn_more_backend": "Viac informácií o serveri TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Keď je synchronizácia vypnutá, všetky údaje zostávajú iba na tomto zariadení. Push notifikácie fungujú lokálne.",
            "onboarding_sync_subtitle": "Keď je zapnutá, TigerDuck synchronizuje úpravy rozvrhu a stavy úloh medzi vašimi zariadeniami prostredníctvom servera TigerDuck.",
            "settings_sync_brief_description": "Synchronizujte úpravy rozvrhu a stavy úloh medzi vašimi zariadeniami.",
            "settings_sync_data_section": "Údaje zdieľané so serverom",
            "settings_sync_disabled_note": "Keď je synchronizácia vypnutá, všetky údaje zostávajú iba na tomto zariadení.",
            "settings_sync_toggle_label": "Zapnúť synchronizáciu medzi zariadeniami",
            "settings_notifications_disabled_warning": "Upozornenia sú vypnuté. Klepnutím otvoríte Nastavenia systému.",
        },
    },
    "sl": {
        "shared": {
            "settings_learn_more_backend": "Več informacij o strežniku TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Ko je sinhronizacija izklopljena, vsi podatki ostanejo samo na tej napravi. Push obvestila delujejo lokalno.",
            "onboarding_sync_subtitle": "Ko je vklopljena, TigerDuck sinhronizira urejanje urnika in stanja nalog med vašimi napravami prek strežnika TigerDuck.",
            "settings_sync_brief_description": "Sinhronizirajte urejanje urnika in stanja nalog med vašimi napravami.",
            "settings_sync_data_section": "Podatki, deljeni s strežnikom",
            "settings_sync_disabled_note": "Ko je sinhronizacija izklopljena, vsi podatki ostanejo samo na tej napravi.",
            "settings_sync_toggle_label": "Vklopi sinhronizacijo med napravami",
            "settings_notifications_disabled_warning": "Obvestila so izklopljena. Tapnite za odpiranje sistemskih nastavitev.",
            "settings_sync_status_off": "Izklopljeno",
            "settings_sync_status_on": "Vklopljeno",
        },
    },
    "sr": {
        "shared": {
            "settings_learn_more_backend": "Сазнајте више о TigerDuck серверу",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Када је синхронизација искључена, сви подаци остају само на овом уређају. Push обавештења раде локално.",
            "onboarding_sync_subtitle": "Када је укључена, TigerDuck синхронизује измене распореда и стања задатака између ваших уређаја преко TigerDuck сервера.",
            "settings_sync_brief_description": "Синхронизујте измене распореда и стања задатака између ваших уређаја.",
            "settings_sync_data_section": "Подаци дељени са сервером",
            "settings_sync_disabled_note": "Када је синхронизација искључена, сви подаци остају само на овом уређају.",
            "settings_sync_toggle_label": "Укључи синхронизацију између уређаја",
            "settings_notifications_disabled_warning": "Обавештења су искључена. Додирните да отворите Подешавања система.",
            "settings_sync_status_off": "Искључено",
            "settings_sync_status_on": "Укључено",
        },
    },
    "sv": {
        "shared": {
            "settings_learn_more_backend": "Läs mer om TigerDuck-servern",
        },
        "apple": {
            "onboarding_sync_disabled_note": "När synkronisering är avstängd stannar all data bara på den här enheten. Push-notiser fungerar lokalt.",
            "onboarding_sync_subtitle": "När den är aktiverad synkroniserar TigerDuck schemaändringar och uppgiftsstatus mellan dina enheter via TigerDuck-servern.",
            "settings_sync_brief_description": "Synkronisera schemaändringar och uppgiftsstatus mellan dina enheter.",
            "settings_sync_data_section": "Data delad med servern",
            "settings_sync_disabled_note": "När synkronisering är avstängd stannar all data bara på den här enheten.",
            "settings_sync_toggle_label": "Aktivera synkronisering mellan enheter",
            "settings_notifications_disabled_warning": "Aviseringar är avstängda. Tryck för att öppna Systeminställningar.",
        },
    },
    "ta": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck பின்தளம் பற்றி மேலும் அறிக",
        },
        "apple": {
            "onboarding_sync_disabled_note": "ஒத்திசைவு முடக்கப்பட்டிருக்கும்போது, எல்லா தரவும் இந்தச் சாதனத்தில் மட்டுமே இருக்கும். புஷ் அறிவிப்புகள் உள்ளூரில் செயல்படும்.",
            "onboarding_sync_subtitle": "இயக்கப்பட்டிருக்கும்போது, TigerDuck சேவையகம் வழியாக உங்கள் சாதனங்களுக்கிடையே நேர அட்டவணை திருத்தங்கள் மற்றும் பணி நிலைகளை TigerDuck ஒத்திசைக்கிறது.",
            "settings_sync_brief_description": "உங்கள் சாதனங்களுக்கிடையே நேர அட்டவணை திருத்தங்கள் மற்றும் பணி நிலைகளை ஒத்திசைக்கவும்.",
            "settings_sync_data_section": "சேவையகத்துடன் பகிரப்பட்ட தரவு",
            "settings_sync_disabled_note": "ஒத்திசைவு முடக்கப்பட்டிருக்கும்போது, எல்லா தரவும் இந்தச் சாதனத்தில் மட்டுமே இருக்கும்.",
            "settings_sync_toggle_label": "குறுக்கு-சாதன ஒத்திசைவை இயக்கவும்",
            "settings_notifications_disabled_warning": "அறிவிப்புகள் முடக்கப்பட்டுள்ளன. கணினி அமைப்புகளைத் திறக்க தட்டவும்.",
            "settings_sync_status_off": "ஆஃப்",
            "settings_sync_status_on": "ஆன்",
        },
    },
    "te": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck బ్యాకెండ్ గురించి మరింత తెలుసుకోండి",
        },
        "apple": {
            "onboarding_sync_disabled_note": "సింక్ ఆఫ్‌లో ఉన్నప్పుడు, మొత్తం డేటా ఈ పరికరంలో మాత్రమే ఉంటుంది. పుష్ నోటిఫికేషన్‌లు స్థానికంగా పనిచేస్తాయి.",
            "onboarding_sync_subtitle": "ఎనేబుల్ చేసినప్పుడు, TigerDuck సర్వర్ ద్వారా మీ పరికరాల మధ్య టైమ్‌టేబుల్ ఎడిట్‌లు మరియు అసైన్‌మెంట్ స్థితులను TigerDuck సింక్ చేస్తుంది.",
            "settings_sync_brief_description": "మీ పరికరాల మధ్య టైమ్‌టేబుల్ ఎడిట్‌లు మరియు అసైన్‌మెంట్ స్థితులను సింక్ చేయండి.",
            "settings_sync_data_section": "సర్వర్‌తో షేర్ చేసిన డేటా",
            "settings_sync_disabled_note": "సింక్ ఆఫ్‌లో ఉన్నప్పుడు, మొత్తం డేటా ఈ పరికరంలో మాత్రమే ఉంటుంది.",
            "settings_sync_toggle_label": "క్రాస్-డివైస్ సింక్‌ను ఎనేబుల్ చేయండి",
            "settings_notifications_disabled_warning": "నోటిఫికేషన్‌లు ఆఫ్‌లో ఉన్నాయి. సిస్టమ్ సెట్టింగ్‌లను తెరవడానికి ట్యాప్ చేయండి.",
            "settings_sync_status_off": "ఆఫ్",
            "settings_sync_status_on": "ఆన్",
        },
    },
    "th": {
        "shared": {
            "settings_learn_more_backend": "เรียนรู้เพิ่มเติมเกี่ยวกับเซิร์ฟเวอร์ TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "เมื่อปิดการซิงค์ ข้อมูลทั้งหมดจะอยู่บนอุปกรณ์นี้เท่านั้น การแจ้งเตือนแบบพุชยังคงทำงานในเครื่อง",
            "onboarding_sync_subtitle": "เมื่อเปิดใช้งาน TigerDuck จะซิงค์การแก้ไขตารางเรียนและสถานะงานระหว่างอุปกรณ์ของคุณผ่านเซิร์ฟเวอร์ TigerDuck",
            "settings_sync_brief_description": "ซิงค์การแก้ไขตารางเรียนและสถานะงานระหว่างอุปกรณ์ของคุณ",
            "settings_sync_data_section": "ข้อมูลที่แชร์กับเซิร์ฟเวอร์",
            "settings_sync_disabled_note": "เมื่อปิดการซิงค์ ข้อมูลทั้งหมดจะอยู่บนอุปกรณ์นี้เท่านั้น",
            "settings_sync_toggle_label": "เปิดใช้งานการซิงค์ข้ามอุปกรณ์",
        },
    },
    "tr": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck Sunucusu hakkında daha fazla bilgi edinin",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Senkronizasyon kapalıyken tüm veriler yalnızca bu cihazda kalır. Push bildirimleri yerel olarak çalışır.",
            "onboarding_sync_subtitle": "Etkinleştirildiğinde, TigerDuck ders programı düzenlemelerini ve ödev durumlarını cihazlarınız arasında TigerDuck sunucusu aracılığıyla senkronize eder.",
            "settings_sync_brief_description": "Ders programı düzenlemelerini ve ödev durumlarını cihazlarınız arasında senkronize edin.",
            "settings_sync_data_section": "Sunucuyla paylaşılan veriler",
            "settings_sync_disabled_note": "Senkronizasyon kapalıyken tüm veriler yalnızca bu cihazda kalır.",
            "settings_sync_toggle_label": "Cihazlar arası senkronizasyonu etkinleştir",
        },
    },
    "uk": {
        "shared": {
            "settings_learn_more_backend": "Дізнатися більше про сервер TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Коли синхронізацію вимкнено, усі дані залишаються лише на цьому пристрої. Push-сповіщення працюють локально.",
            "onboarding_sync_subtitle": "Коли увімкнено, TigerDuck синхронізує зміни розкладу та стани завдань між вашими пристроями через сервер TigerDuck.",
            "settings_sync_brief_description": "Синхронізуйте зміни розкладу та стани завдань між вашими пристроями.",
            "settings_sync_data_section": "Дані, що передаються серверу",
            "settings_sync_disabled_note": "Коли синхронізацію вимкнено, усі дані залишаються лише на цьому пристрої.",
            "settings_sync_toggle_label": "Увімкнути синхронізацію між пристроями",
        },
    },
    "ur": {
        "shared": {
            "settings_learn_more_backend": "TigerDuck بیک اینڈ کے بارے میں مزید جانیں",
        },
        "apple": {
            "onboarding_sync_disabled_note": "جب سنک بند ہو تو تمام ڈیٹا صرف اس آلے پر رہتا ہے۔ پش نوٹیفکیشنز مقامی طور پر کام کرتی ہیں۔",
            "onboarding_sync_subtitle": "فعال ہونے پر، TigerDuck آپ کے آلات کے درمیان ٹائم ٹیبل ترامیم اور اسائنمنٹ کی حالتوں کو TigerDuck سرور کے ذریعے سنک کرتا ہے۔",
            "settings_sync_brief_description": "اپنے آلات کے درمیان ٹائم ٹیبل ترامیم اور اسائنمنٹ کی حالتیں سنک کریں۔",
            "settings_sync_data_section": "سرور کے ساتھ شیئر کیا گیا ڈیٹا",
            "settings_sync_disabled_note": "جب سنک بند ہو تو تمام ڈیٹا صرف اس آلے پر رہتا ہے۔",
            "settings_sync_toggle_label": "کراس ڈیوائس سنک فعال کریں",
            "settings_notifications_disabled_warning": "نوٹیفکیشنز بند ہیں۔ سسٹم سیٹنگز کھولنے کے لیے ٹیپ کریں۔",
            "settings_sync_status_off": "بند",
            "settings_sync_status_on": "آن",
        },
    },
    "vi": {
        "shared": {
            "settings_learn_more_backend": "Tìm hiểu thêm về máy chủ TigerDuck",
        },
        "apple": {
            "onboarding_sync_disabled_note": "Khi đồng bộ tắt, tất cả dữ liệu chỉ lưu trên thiết bị này. Thông báo đẩy vẫn hoạt động cục bộ.",
            "onboarding_sync_subtitle": "Khi bật, TigerDuck đồng bộ các chỉnh sửa thời khóa biểu và trạng thái bài tập giữa các thiết bị của bạn qua máy chủ TigerDuck.",
            "settings_sync_brief_description": "Đồng bộ các chỉnh sửa thời khóa biểu và trạng thái bài tập giữa các thiết bị của bạn.",
            "settings_sync_data_section": "Dữ liệu được chia sẻ với máy chủ",
            "settings_sync_disabled_note": "Khi đồng bộ tắt, tất cả dữ liệu chỉ lưu trên thiết bị này.",
            "settings_sync_toggle_label": "Bật đồng bộ xuyên thiết bị",
        },
    },
    "yue-HK": {
        "shared": {
            "settings_learn_more_backend": "了解更多有關 TigerDuck 後端伺服器嘅資訊",
        },
        "apple": {
            "onboarding_sync_disabled_note": "關咗同步之後，所有資料淨係儲喺呢部裝置。推送通知仲係可以喺本機正常運作。",
            "onboarding_sync_subtitle": "啟用之後，TigerDuck 會透過 TigerDuck 伺服器喺你嘅裝置之間同步課表編輯同功課狀態。",
            "settings_sync_brief_description": "喺你嘅裝置之間同步課表編輯同功課狀態。",
            "settings_sync_data_section": "同伺服器共享嘅資料",
            "settings_sync_disabled_note": "關咗同步之後，所有資料淨係儲喺呢部裝置。",
            "settings_sync_toggle_label": "啟用跨裝置同步",
        },
    },
    "zh-Hans": {
        "shared": {
            "settings_learn_more_backend": "了解更多关于 TigerDuck 后端服务器的信息",
        },
        "apple": {
            "onboarding_sync_disabled_note": "关闭同步后，所有数据仅保存在此设备上。推送通知仍可在本地正常工作。",
            "onboarding_sync_subtitle": "启用后，TigerDuck 会通过 TigerDuck 服务器在你的设备间同步课表编辑和作业状态。",
            "settings_sync_brief_description": "在你的设备间同步课表编辑与作业状态。",
            "settings_sync_data_section": "与服务器共享的数据",
            "settings_sync_disabled_note": "关闭同步后，所有数据仅保存在此设备上。",
            "settings_sync_toggle_label": "启用跨设备同步",
        },
    },
}
# fmt: on


def main():
    updated_count = 0
    skipped_count = 0

    for locale, groups in sorted(TRANSLATIONS.items()):
        path = os.path.join(SOURCE_DIR, f"{locale}.json")
        if not os.path.exists(path):
            print(f"WARN: {locale}.json not found, skipping")
            continue

        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        changed = False

        for group_name, keys in groups.items():
            en_ref = EN_SHARED if group_name == "shared" else EN_APPLE
            for key, translation in keys.items():
                en_val = en_ref.get(key)
                if en_val is None:
                    print(f"WARN: {key} not in EN reference, skipping")
                    continue
                current = data.get(group_name, {}).get(key, "")
                if current == en_val:
                    data[group_name][key] = translation
                    changed = True
                    updated_count += 1
                else:
                    skipped_count += 1

        if changed:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")
            print(f"  Updated {locale}.json")

    print(f"\nDone: {updated_count} translations applied, {skipped_count} already translated (skipped)")


if __name__ == "__main__":
    main()
