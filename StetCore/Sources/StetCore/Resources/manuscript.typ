// Stet – Manuskriptformat (Pandoc-Vorlage für Typst)
// A4, Times 12 pt, großer Zeilenabstand, Einzug statt Absatzabstand, Kopfzeile mit Name, Titel
// und Seitenzahl, Fußzeile mit der Fassung – damit jede ausgedruckte Seite zuzuordnen ist.

#let scenebreak() = block(width: 100%, above: 1.4em, below: 1.4em, align(center)[\#])
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
  font: ("Times New Roman", "Libertinus Serif"),
  size: 12pt,
)
$if(stet-keep-quotes)$
#set smartquote(enabled: false)
$endif$
#set par(justify: false, leading: 1.15em, spacing: 1.15em, first-line-indent: 1.25cm)
#set page(
  paper: "a4",
  margin: (x: 2.5cm, top: 3cm, bottom: 2.6cm),
  header: context {
    if here().page() > 1 {
      set text(size: 10pt)
      h(1fr)
      [$for(author)$$author$$sep$, $endfor$ · $title$ · #counter(page).display()]
    }
  },
  footer: context {
    if here().page() > 1 {
      set text(size: 8pt, fill: luma(110))
      h(1fr)
      [$stet-version-line$]
    }
  },
)

// Headings are blocks, so the paragraph after them starts without indent.
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  v(5cm)
  block(width: 100%, below: 1.6cm, align(center, text(size: 14pt, weight: "regular", it.body)))
}
#show heading.where(level: 2): it => {
  pagebreak(weak: true)
  v(5cm)
  block(width: 100%, below: 1.4cm, align(center, text(size: 13pt, weight: "regular", it.body)))
}
#show heading.where(level: 3): it => block(above: 1.6em, below: 1em, align(center, text(size: 11pt, style: "italic", it.body)))
// Quotes (a letter, an epigraph …): indented on both sides, with air around and a smaller
// indent for their own paragraphs (the full one on top of the quote's would look lost).
#show quote.where(block: true): it => block(above: 2.1em, below: 2.1em, inset: (left: 1.25cm, right: 1.25cm), {
  set par(first-line-indent: 0.6cm)
  it.body
})

// Titelseite
#page(header: none, footer: none)[
  #set par(first-line-indent: 0pt, leading: 0.65em)
  $for(author)$$author$$sep$ \ $endfor$
  #v(1fr)
  #align(center)[
    #text(size: 20pt)[$title$]
    #v(0.8em)
    #text(size: 12pt)[$for(author)$$author$$sep$, $endfor$]
    #v(2.5em)
    #text(size: 11pt)[ca. $stet-words$ Wörter]
  ]
  #v(1fr)
  #text(size: 9pt, fill: luma(110))[$stet-version-line$]
]
#counter(page).update(1)

$body$
