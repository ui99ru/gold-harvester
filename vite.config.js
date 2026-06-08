import { defineConfig } from 'vite';
import { viteSingleFile } from 'vite-plugin-singlefile';

// build -> единый самодостаточный dist/index.html (Rapier-compat вшивает wasm внутрь),
// который харнесс грузит через file:// как раньше. dev -> модули + HMR.
export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    target: 'es2020',
    assetsInlineLimit: 100000000,
    chunkSizeWarningLimit: 100000,
  },
});
