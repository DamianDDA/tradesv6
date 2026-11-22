// A new canvas is mounted on each book update. Draw after layout at the display's pixel density.
function priceChart(market) {
  const chart = node('div', null, 'price-chart');
  const tape = asList(market.book.tape);
  if (!tape.length) {
    chart.append(node('p', 'Awaiting the first matched trade', 'chart-empty'));
    return chart;
  }
  const canvas = node('canvas');
  canvas.role = 'img';
  canvas.setAttribute('aria-label', market.options[0] + ' last trade price: ' + tape[tape.length - 1].price + ' cents');
  chart.append(canvas);
  requestAnimationFrame(() => {
    if (!canvas.isConnected) return;
    const w = canvas.clientWidth, h = canvas.clientHeight;
    if (w < 20 || h < 20) return;
    const scale = window.devicePixelRatio || 1;
    canvas.width = Math.round(w * scale);
    canvas.height = Math.round(h * scale);
    const c = canvas.getContext('2d');
    c.scale(scale, scale);
    const left = 5, right = w - 38, top = 9, bottom = h - 23;
    const start = tape[0].time;
    const end = tape[tape.length - 1].time;
    const x = t => left + (right - left) * (end > start ? (t - start) / (end - start) : 0.5);
    const y = p => bottom - p / 100 * (bottom - top);
    c.font = '10px system-ui';
    for (const price of [0, 25, 50, 75, 100]) {
      c.strokeStyle = '#413630';
      c.beginPath(); c.moveTo(left, y(price)); c.lineTo(right, y(price)); c.stroke();
      c.fillStyle = '#c4baad'; c.fillText(price + '¢', right + 5, y(price) + 3);
    }
    c.strokeStyle = '#ff5856';
    c.lineWidth = 2;
    c.beginPath(); c.moveTo(x(start), y(tape[0].price));
    tape.slice(1).forEach((t, i) => {
      c.lineTo(x(t.time), y(tape[i].price)); c.lineTo(x(t.time), y(t.price));
    });
    c.stroke();
    const latest = tape[tape.length - 1];
    c.fillStyle = '#f5f2d8'; c.beginPath(); c.arc(x(end), y(latest.price), 3, 0, Math.PI * 2); c.fill();
    const clock = t => new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    c.fillStyle = '#c4baad'; c.fillText(clock(start), left, h - 5);
    if (end > start + 1) { c.textAlign = 'right'; c.fillText(clock(end), right, h - 5); }
  });
  return chart;
}

const orderDrafts = new Map();

function tradingCard(market) {
  const { id, options, book } = market;
  const panel = node('div', null, 'trading');
  const tape = asList(book.tape);
  const last = tape[tape.length - 1];
  const headline = node('div', null, 'chart-title');
  headline.append(node('strong', options[0]), node('strong', last ? last.price + '¢' : '—'));
  panel.append(headline, priceChart(market));
  const levels = node('div', null, 'depth');
  for (const [label, rows] of [['Bids', book.bids], ['Asks', book.asks]]) {
    const col = node('div');
    col.append(node('h3', options[0] + ' · ' + label));
    const quotes = asList(rows).slice(0, 3);
    for (const quote of quotes) col.append(node('p', quote.price + '¢ × ' + quote.quantity));
    if (!quotes.length) col.append(node('p', '—'));
    levels.append(col);
  }
  panel.append(levels);
  if (book.shares.some(q => q > 0)) {
    panel.append(node('p', 'Your shares · ' + options.map((o, i) => o + ' ' + book.shares[i]).join(' / '), 'meta'));
    if (last && market.status !== 'settled') {
      const net = book.sold + book.shares[0] * last.price + book.shares[1] * (100 - last.price) - book.spent[0] - book.spent[1];
      panel.append(node('p', 'Estimated P&L at last trade · ' + money(net), 'meta'));
    }
  }
  if (tab !== 'admin' && market.status === 'open' && !state.pending) {
    const values = orderDrafts.get(id) || { kind: 'buy', side: '1', price: '', quantity: '' };
    const form = node('form', null, 'order-ticket');
    const kind = node('select');
    for (const label of ['Buy', 'Sell']) { const o = node('option', label); o.value = label.toLowerCase(); kind.append(o); }
    const side = outcomeSelect(options);
    const price = node('input'), quantity = node('input');
    Object.assign(price, { type: 'number', required: true, min: 1, max: 99, step: 1, placeholder: '1–99' });
    Object.assign(quantity, { type: 'number', required: true, min: 1, max: 10000, step: 1, placeholder: 'Shares' });
    const total = node('p', '', 'meta');
    const submit = button('Place order', null, 'primary');
    submit.type = 'submit';
    function estimate() {
      const amount = Number(values.price) * Number(values.quantity);
      if (values.kind === 'buy') {
        const profit = Number(values.quantity) * 100 - amount;
        total.textContent = amount > 0 && profit >= 0
          ? 'Reserve ' + money(amount) + ' · Profit if filled at limit and correct: ' + money(profit)
          : 'Winning shares pay $1 each';
      } else {
        total.textContent = amount ? 'Minimum proceeds if filled · ' + money(amount) : 'Sell from your available shares';
      }
    }
    for (const [key, title, input] of [['kind', 'Order', kind], ['side', 'Outcome', side], ['price', 'Limit (¢)', price], ['quantity', 'Shares', quantity]]) {
      input.value = values[key];
      input.dataset.field = id + '-' + key;
      input.oninput = () => { values[key] = input.value; orderDrafts.set(id, values); estimate(); };
      const wrap = node('label', title);
      wrap.append(input); form.append(wrap);
    }
    estimate();
    form.append(total, submit);
    form.onsubmit = event => {
      event.preventDefault();
      request(kind.value, { id, side: Number(side.value), price: price.valueAsNumber, quantity: quantity.valueAsNumber });
    };
    panel.append(form);
    for (const order of asList(book.mine)) {
      const row = node('div', null, 'working-order');
      row.append(node('span', order.kind + ' ' + order.quantity + ' ' + options[order.side-1] + ' @ ' + order.price + '¢'),
        button('Cancel unfilled', () => request('cancel', { id, order: order.id })));
      panel.append(row);
    }
  }
  return panel;
}
