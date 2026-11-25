// Builds the editor into dist/ (index.html, editor.js, editor.css, samples/).
//   node build.mjs           production build (minified)
//   node build.mjs --serve   watch + dev server on http://localhost:5173/
import { cp, mkdir, rm } from "node:fs/promises";
import * as esbuild from "esbuild";

const serve = process.argv.includes("--serve");
const outdir = "dist";

await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });
await cp("public", outdir, { recursive: true });

/** @type {import("esbuild").BuildOptions} */
const options = {
  entryPoints: ["src/main.ts"],
  bundle: true,
  format: "iife",
  target: ["safari17", "chrome120"],
  outfile: `${outdir}/editor.js`,
  sourcemap: serve ? "inline" : false,
  minify: !serve,
  logLevel: "info",
};

if (serve) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  const { port } = await ctx.serve({ servedir: outdir, port: Number(process.env.PORT ?? 5173) });
  console.log(`Zadur editor dev server: http://localhost:${port}/`);
} else {
  await esbuild.build(options);
}
