-- Yalnız yerel yığın (oyun-test). Tanıtım sayfası ve testlerin sahte oyunu.
insert into ortak.oyunlar (id, ad, ayarlar) values (
  'deneme', 'Deneme Oyunu', '{
    "ad": { "en_az": 3, "en_cok": 16, "degistirme_gun": 30, "yasakli": ["deneme"], "onekler": ["Bekçi", "Çoban", "Kahveci", "Avcı"] },
    "hesap": { "baglama_odulu": "deneme-rozet" },
    "siralama": { "yon": "azalan", "esitlik": "ikincil", "dagilim_esigi": 50 },
    "lig": { "kademeler": ["Toprak", "Bakır", "Gümüş", "Altın", "Firuze"], "grup_boyu": 50,
             "cikis_orani": 0.2, "inis_orani": 0.2, "en_iyi_gun": 5, "esitlik": "ortak", "bant_genisligi": 0 }
  }'
);

insert into ortak.urunler (urun, oyun_id, hak) values ('deneme_tam', 'deneme', 'tam');
