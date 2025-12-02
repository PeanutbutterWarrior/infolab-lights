const pixelSize = 3;
const pixelWidth = Math.ceil(120 / pixelSize);
const pixelHeight = Math.ceil(80 / pixelSize);

function bigPixel(pos, color, display) {
  for (let dx=0; dx <pixelSize; dx++) {
    for (let dy=0; dy < pixelSize; dy++) {
      display.setPixel(
        pos[0] * pixelSize + dx,
        pos[1] * pixelSize + dy,
        color
      );
    }
  }
}

function modulo(x, mod) {
  // In javascript % is remainder
  return (x % mod + mod) % mod
}

function posEqual(p1, p2) {
  return p1[0] === p2[0] && p2[1] === p1[1];
}

class Player {
  constructor() {
    this.resetPos();
    this.color = [Math.floor(Math.random() * 255), Math.floor(Math.random() * 255), Math.floor(Math.random() * 255)];
  }

  resetPos() {
    this.head = [Math.floor(pixelWidth / 2), Math.floor(pixelHeight / 2)];
    this.body = [];
    this.length = 4;
    this.direction = [1, 0];
  }

  move() {
    this.body.push(this.head);
    this.head = [
      modulo(this.head[0] + this.direction[0], pixelWidth),
      modulo(this.head[1] + this.direction[1], pixelHeight)
    ]
    if (this.body.length > this.length) {
      this.body.shift();
    }
  }

  handleInput(dir) {
    switch (dir) {
        case "ArrowUp":
          this.direction = [0, -1];
          break;
        case "ArrowDown":
          this.direction = [0, 1];
          break;
        case "ArrowLeft":
          this.direction = [-1, 0];
          break;
        case "ArrowRight":
          this.direction = [1, 0];
          break;
    }
  }

  draw(display) {
    bigPixel(this.head, [255, 255, 255], display);
    for (const segment of this.body) {
      bigPixel(segment, this.color, display);
    }
  }

  checkAppleCollision(apple) {
    if (posEqual(this.head, apple)) {
      this.length++;
      return true;
    }
    return false;
  }

  checkSnakeCollision(other) {
    let bodyCollision = false;
    for (const segment of other.body) {
      if (posEqual(this.head, segment)) {
        bodyCollision = true;
      }
    }
    return bodyCollision || posEqual(this.head, other.head);
  }
}

return class MyEffect {
  constructor(display) {
    this.display = display;
    this.snakes = [];
    this.#clear();
    this.cooldown = 0;
    this.#newApple();
  }

  #newApple() {
    this.apple = [
      Math.floor(Math.random() * pixelWidth),
      Math.floor(Math.random() * pixelHeight),
    ]
  }

  #clear() {
    for (let x = 0; x < this.display.width; x++) {
      for (let y = 0; y < this.display.height; y++) {
        this.display.setPixel(x, y, [0, 0, 0]);
      }
    }
  }

  update() {
    if (this.cooldown > 0) {
      this.cooldown--;
      return;
    }
    this.cooldown = 3;
    
    this.#clear();
    let deadSnakes = [];
    let newApple = false;
    
    for (const snake of this.snakes) {
      snake.move()
      for (const otherSnake of this.snakes) {
        if (snake === otherSnake) continue;
        if (snake.checkSnakeCollision(otherSnake))
          deadSnakes.push(snake);
      }
      if (snake.checkAppleCollision(this.apple)) {
        newApple = true;
      }
      snake.draw(this.display);
    }
    
    if (newApple)
      this.#newApple();
    for (const snake of deadSnakes)
      snake.resetPos();
    bigPixel(this.apple, [255, 0 ,0], this.display)
    this.display.flush();
  }

  addPlayer(player) {
    this.snakes.push(new Player());
  }

  removePlayer(player) {
    this.snakes.splice(player - 1, 1);
  }

  onKeypress(dir, player) {
    this.snakes[player - 1].handleInput(dir)
  }
}
