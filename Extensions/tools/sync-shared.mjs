import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
for (const name of ["rules.js", "video-button.js"]) {
  const source = join(root, "shared", name);
  for (const target of [`chrome/${name}`, `safari/Resources/${name}`]) {
    const destination = join(root, target);
    mkdirSync(dirname(destination), { recursive: true });
    copyFileSync(source, destination);
    console.log(`synced ${target}`);
  }
}
