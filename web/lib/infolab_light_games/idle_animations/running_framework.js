import { writeAllSync } from "https://deno.land/std@0.113.0/streams/conversion.ts";
import { pack } from 'https://deno.land/x/msgpackr@v1.3.2/index.js';

console.log = console.trace;
console.debug = console.trace;
console.info = console.trace;

async function readStdin() {
    const bytes = [];

    while (true) {
        const buffer = new Uint8Array(1);
        const readStatus = await Deno.stdin.read(buffer);

        if (readStatus === null || readStatus === 0) {
            break;
        }

        const byte = buffer[0];

        if (byte === 10) {
            break;
        }

        bytes.push(byte);
    }

    return Uint8Array.from(bytes);
}

class Display {
    #buffer;

    constructor(width, height) {
    this.width = width;
    this.height = height;

    this.#buffer = Array.from(Array(width), () => Array.from(Array(height), () => [0, 0, 0]));
    }

    setPixel(x, y, [r, g, b]) {
    this.#buffer[x][y] = [r, g, b];
    }

    flush() {
    const pixels = this.#buffer.flatMap((col, x) => {
        return col.map(([r, g, b], y) => ({x: x | 0, y: y | 0, v: [r | 0, g | 0, b | 0]}));
    });

    const chunkSize = 1000;
    const len = pixels.length;
    for (let i = 0; i < len; i += chunkSize) {
        writeAllSync(Deno.stdout, pack(pixels.slice(i, i + chunkSize)));
    }
    }
}

const effect = (() => {
    // Code
})();

const inst = new effect(new Display(120, 80));

while (true) {
    let r = new TextDecoder().decode(await readStdin()).trim();
    if (!r) {
        console.log("Empty string received, quitting");
        break;
    }
    let {msg: msg} = JSON.parse(r);

    // msg should always be "tick"

    inst.update();
}