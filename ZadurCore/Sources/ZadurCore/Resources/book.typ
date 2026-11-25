// Zadur – Buchsatz (Pandoc-Vorlage für Typst)
// 13,5 × 21 cm, Blocksatz mit Silbentrennung, Einzug, Kolumnentitel (links Autor:in, rechts das
// Kapitel), Kapitel beginnen auf rechten Seiten, Titelei mit Impressum und Fassung.

#let scenebreak() = block(width: 100%, above: 1.2em, below: 1.2em, align(center, text(fill: luma(60))[⁂]))
#let horizontalRule = scenebreak()
#let divider() = scenebreak()

#set document(
  title: [$title$],
  author: ($for(author)$"$author$"$sep$, $endfor$),
)
#set text(
  lang: "$typst-lang$",
$if(typst-region)$
  region: "$typst-region$",
$endif$
  font: ("Iowan Old Style", "Palatino", "Libertinus Serif"),
  size: 10.5pt,
  hyphenate: true,
)
$if(zadur-keep-quotes)$
#set smartquote(enabled: false)
$endif$
#set par(justify: true, leading: 0.7em, spacing: 0.7em, first-line-indent: 1.1em)

#let book-title = [$title$]
#let book-author = [$for(author)$$author$$sep$, $endfor$]

#let running-head() = context {
  let page-number = here().page()
  // No running head on pages where a chapter or part begins.
  let starts = query(heading.where(level: 1)).filter(h => h.location().page() == page-number)
  let starts2 = query(heading.where(level: 2)).filter(h => h.location().page() == page-number)
  if starts.len() > 0 or starts2.len() > 0 { return }
  set text(size: 8pt, tracking: 0.06em)
  if calc.even(page-number) {
    upper(book-author)
  } else {
    let chapters = query(heading.where(level: $if(zadur-has-parts)$2$else$1$endif$).before(here()))
    h(1fr)
    if chapters.len() > 0 { upper(chapters.last().body) } else { upper(book-title) }
  }
}

#set page(
  width: 13.5cm,
  height: 21cm,
  binding: left,
  margin: (inside: 2cm, outside: 1.6cm, top: 2.1cm, bottom: 2.3cm),
  header: running-head(),
  footer: context align(center, text(size: 8.5pt, counter(page).display())),
)

// Headings are blocks, so the paragraph after them starts without indent.
#show heading.where(level: 1): it => {
  pagebreak(weak: true, to: "odd")
  v(24%)
  block(width: 100%, below: 2.6em, align(center, text(size: 15pt, style: "italic", weight: "regular", it.body)))
}
#show heading.where(level: 2): it => {
  pagebreak(weak: true, to: "odd")
  v(24%)
  block(width: 100%, below: 2.4em, align(center, text(size: 14pt, style: "italic", weight: "regular", it.body)))
}
#show heading.where(level: 3): it => block(above: 1.4em, below: 0.9em, align(center, text(size: 9.5pt, tracking: 0.08em, upper(it.body))))
// Quotes (a letter, an epigraph …): indented on both sides, a little smaller, with air around.
#show quote.where(block: true): it => block(above: 1.1em, below: 1.1em, inset: (left: 1.2em, right: 1.2em), text(size: 9.5pt, it.body))

// Titelei
#set page(header: none, footer: none)
$if(zadur-cover)$
#page(margin: 0pt)[#image("$zadur-cover$", width: 100%, height: 100%, fit: "cover")]
#page[]
$endif$
#page[
  #set par(first-line-indent: 0pt, justify: false)
  #v(22%)
  #align(center)[
    #text(size: 11pt, tracking: 0.08em)[#upper(book-author)]
    #v(1.6em)
    #text(size: 22pt, style: "italic")[#book-title]
  ]
]
#page[
  #set par(first-line-indent: 0pt, justify: false)
  #set text(size: 8pt)
  #v(1fr)
  © $zadur-year$ #book-author \
  $zadur-version-line$ \
  Gesetzt mit Zadur aus der $if(zadur-font)$$zadur-font$$else$Iowan Old Style$endif$.
]

#set page(header: running-head(), footer: context align(center, text(size: 8.5pt, counter(page).display())))
#counter(page).update(1)

$body$
