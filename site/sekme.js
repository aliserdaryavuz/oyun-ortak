// Görünen bölümün ve dilin sekmesini işaretler (görünürlük CSS'te; bu yalnız vurgu ve erişilebilirlik için).
const isaretle = () => {
  const gorunen = [...document.querySelectorAll(".bolum")].find((b) => b.offsetParent);
  if (!gorunen) return;
  const en = !!gorunen.closest(".dil.en");
  for (const a of document.querySelectorAll(".bolumler a, .diller a")) {
    const etkin = a.classList.contains("d-en") ? en : a.classList.contains("d-tr") ? !en : a.getAttribute("href") === "#" + gorunen.id;
    if (etkin) a.setAttribute("aria-current", "true"); else a.removeAttribute("aria-current");
  }
  // Dil düğmesi öbür dilin karşılık gelen bölümüne gider (genel kural: dil değişince sayfa değişmez)
  const karsi = gorunen.dataset.karsi;
  if (karsi) document.querySelector(en ? ".diller .d-tr" : ".diller .d-en").setAttribute("href", "#" + karsi);
  // Panel her sekme değişiminde başa döner
  gorunen.closest(".panel").scrollTop = 0;
};
addEventListener("hashchange", isaretle);
// İlk yüklemede yerleşim hazır olmadan hesaplanabilir; dil düğmesine basılınca yeniden hesaplanır (tıklama, gezinmeden önce çalışır).
document.querySelector(".diller")?.addEventListener("click", isaretle);
isaretle();
