export interface PromiseSetOptions {
  logger?: (text: string) => void;
}

/*
 * a promise set is like a promise that can be resolved multiple times as
 * new results are added.
 *
 * it starts out with zero values and zero listeners.
 *
 * whenever a new value is posted, it's sent immediately to all listeners.
 * the value set can grow but never shrink.
 *
 * whenever a new listener is attached, it will immediately receive all
 * current values. if a new value is added later, it will receive the new
 * value later.
 *
 * the added value may not be null.
 */
export class PromiseSet<T> {
  values: T[] = [];
  listeners: ((value: T) => void)[] = [];

  constructor(public options: PromiseSetOptions = {}) {
    // pass
  }

  add(value: T) {
    this.values.push(value);
    if (this.options.logger) this.options.logger(value["inspect"] ? value["inspect"]() : value.toString());
    this.listeners.forEach(f => f(value));
  }

  then(callback: (value: T) => void) {
    this.listeners.push(callback);
    this.values.forEach(callback);
  }

  get isSettled() {
    return (this.values.length > 0);
  }
}
