const tag = (target: { prototype: { tag?: string } }) => {
  target.prototype.tag = "decorated";
};

const shout = (_target: object, _key: string, descriptor: PropertyDescriptor) => {
  const original = descriptor.value as () => string;
  descriptor.value = function (this: unknown) {
    return original.call(this).toUpperCase();
  };
};

@tag
export class Decorated {
  declare tag: string;

  @shout
  name() {
    return "method";
  }
}
