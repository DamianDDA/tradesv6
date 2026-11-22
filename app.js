const exchange = document.querySelector('#exchange');
const resultOverlay = document.querySelector('#trade-result');
const resultCurrency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const recentResults = new Set();
const resultQueue = [];
let activeResultId = null;

const content = document.querySelector('#content');
const notice = document.querySelector('#notice');
const tabs = [...document.querySelectorAll('[data-tab]')];
let state = null;
let tab = 'open';
let polling = false;
let queuedAction;
let openSession = 0;
let renderedState;
let draft = {};
let waiting = false;
let timeout;

const asList = value => Array.isArray(value) ? value : [];
const money = cents => new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD',
}).format(cents / 100);
const date = seconds => new Date(seconds * 1000).toLocaleString([], {
  dateStyle: 'medium', timeStyle: 'short',
});

function node(tag, value, style) {
  const element = document.createElement(tag);
  if (value != null) element.textContent = value;
  if (style) element.className = style;
  return element;
}

function showNotice(message) {
  notice.textContent = message || '';
  notice.hidden = !message;
}

function post(route, data = {}) {
  return fetch('https://' + GetParentResourceName() + '/' + route, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data),
  });
}

function setWaiting(value) {
  waiting = value;
  document.querySelectorAll('#content button').forEach(button => {
    button.disabled = value;
  });
}

function request(action, fields = {}, silent = false) {
  if (waiting || (silent && polling)) return;
  if (polling) {
    if (!silent) queuedAction = { action, fields };
    return;
  }
  polling = silent;
  if (!silent) {
    setWaiting(true);
    showNotice('');
  }
  timeout = setTimeout(() => {
    setWaiting(false);
    polling = false;
    queuedAction = undefined;
    showNotice('The bank is taking longer than expected to respond. Check your cash and wager before retrying.');
  }, 8000);
  post('request', { action, ...fields }).catch(() => {
    clearTimeout(timeout);
    setWaiting(false);
    polling = false;
    queuedAction = undefined;
    showNotice('Connection failed. The exchange will retry automatically.');
  });
}

function button(label, handler, style) {
  const element = node('button', label, style);
  element.type = 'button';
  element.onclick = handler;
  return element;
}

function outcomeSelect(options) {
  const select = node('select');
  select.setAttribute('aria-label', 'Outcome');
  options.forEach((label, index) => {
    const choice = node('option', label);
    choice.value = index + 1;
    select.append(choice);
  });
  return select;
}

function arm(button, label, action) {
  button.onclick = () => {
    button.textContent = label;
    button.onclick = action;
  };
}

function card(market) {
  const root = node('article', null, 'card');
  const { id, options, totals, position, claim } = market;
  const total = totals[0] + totals[1];
  const share = total ? Math.round(100 * totals[0] / total) : 50;
  const label = market.status === 'refunded' ? 'Refunded'
    : market.winner ? 'Won by ' + options[market.winner - 1] : market.status;
  const metadata = node('div', null, 'market-meta');
  metadata.append(node('span', label, 'badge'), node('p', market.book ? market.book.volume + ' shares traded' : 'Pool ' + money(total), 'meta'));
  const closeLabel = market.status === 'open' ? 'Closes ' + date(market.closes) : 'Wagering ended';
  root.append(metadata, node('h2', market.title), node('p', closeLabel, 'meta'),
    node('p', market.rules, 'rules'));

  if (market.book) {
    root.append(tradingCard(market));
  } else {
    const bar = node('div', null, 'bar');
    bar.setAttribute('aria-hidden', 'true');
    const fill = node('span');
    fill.style.width = share + '%';
    bar.append(fill);
    const split = node('div', null, 'split');
    split.append(...options.map((name, index) => node('span', name + (total ? ' · ' + (index ? 100 - share : share) + '%' : ''))));
    root.append(split);
    if (total) root.append(bar);
    if (position[0] || position[1]) {
      const bets = options.map((name, index) => name + ' ' + money(position[index]));
      root.append(node('p', 'Your wagers · ' + bets.join(' / '), 'meta'));
    }

  }

  const actions = node('form', null, 'actions');
  actions.onsubmit = event => event.preventDefault();
  if (tab === 'admin') {
    if (market.status === 'open') actions.append(button('Close now', event => request('close', { id })));
    if (market.status === 'closed') {
      const side = outcomeSelect(options);
      const settle = button('Settle market', null, 'primary');
      const reset = () => arm(settle, 'Confirm ' + options[Number(side.value) - 1],
        () => request('settle', { id, side: Number(side.value) }));
      side.onchange = () => { settle.textContent = 'Settle market'; reset(); };
      reset();
      actions.append(side, settle);
    }
  } else if (claim && !state.pending) {
    actions.append(button('Claim ' + money(claim), () => request('claim', { id }), 'primary'));
  } else if (!market.book && market.status === 'open' && !state.pending) {
    const side = outcomeSelect(options);
    const amount = node('input');
    amount.type = 'number';
    amount.required = true;
    amount.min = state.min;
    amount.max = state.max;
    amount.step = 1;
    amount.placeholder = '$ Cash';
    amount.setAttribute('aria-label', 'Wager in whole dollars');
    const submit = button('Place wager', null, 'primary');
    submit.type = 'submit';
    actions.onsubmit = event => {
      event.preventDefault();
      request('bet', { id, side: Number(side.value), amount: amount.valueAsNumber });
    };
    actions.append(side, amount, submit);
  }
  if (actions.children.length) root.append(actions);
  return root;
}

function createForm() {
  const form = node('form', null, 'card form admin-section');
  const field = (label, tag, attributes) => {
    const wrapper = node('label', label);
    const input = node(tag);
    Object.assign(input, { required: true }, attributes);
    if (Object.hasOwn(draft, input.name)) input.value = draft[input.name];
    input.oninput = () => { draft[input.name] = input.value; };
    wrapper.append(input);
    return wrapper;
  };
  const row = node('div', null, 'grid');
  row.append(field('First outcome', 'input', { name: 'first', value: 'Yes', maxLength: 40 }),
    field('Second outcome', 'input', { name: 'second', value: 'No', maxLength: 40 }),
    field('Minutes until close', 'input', { name: 'minutes', type: 'number', min: 1, max: 43200, value: 60 }));
  const publish = button('Publish market', null, 'primary');
  publish.type = 'submit';
  form.append(node('h2', 'Create a market'), field('Market question', 'input', {
    name: 'title', placeholder: 'Will the Marshals win Saturday’s race?', maxLength: 120,
  }), field('Resolution rules', 'textarea', { name: 'rules', rows: 2, maxLength: 800 }),
  row, publish);
  form.onsubmit = event => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(form));
    request('create', { ...values, minutes: Number(values.minutes) });
  };
  return form;
}

function reviewCard(review) {
  const root = node('article', null, 'card');
  root.append(node('h2', 'Cash review · Market #' + review.market),
    node('p', review.name + ' · ' + review.kind + ' · ' + date(review.time)),
    node('p', 'Character ' + review.key + ' · Before ' + money(review.before) + ' · Expected ' + money(review.after), 'meta'));
  const actions = node('div', null, 'actions');
  for (const applied of [true, false]) {
    const label = applied ? 'Cash moved' : 'Cash did not move';
    const choice = button(label);
    arm(choice, 'Confirm: ' + label, () => request('review', { key: review.key, applied }));
    actions.append(choice);
  }
  root.append(actions);
  return root;
}

function renderStats() {
  const stats = state.stats;
  const summary = node('div', null, 'stats-grid');
  const net = stats.profit - stats.loss;
  const signed = amount => amount === 0 ? money(0) : (amount > 0 ? '+' : '−') + money(Math.abs(amount));
  for (const [label, value, style] of [
    ['Net result', signed(net), net < 0 ? 'negative' : ''],
    ['Profit', money(stats.profit), ''],
    ['Loss', money(stats.loss), 'negative'],
    ['Open stakes', money(stats.exposure), ''],
  ]) {
    const metric = node('div', null, 'card metric');
    metric.append(node('span', label, 'meta'), node('strong', value, style));
    summary.append(metric);
  }

  content.append(node('h2', 'Profit & loss'), summary,
    node('p', stats.count + ' settled markets · Results include claimable cash', 'meta'),
    node('h2', 'Recent results', 'ledger-heading'));
  const results = asList(stats.results);
  if (!results.length) {
    content.append(node('p', 'No recent results.', 'meta empty'));
    return;
  }
  const scroll = node('div', null, 'ledger-scroll');
  const table = node('table', null, 'ledger');
  const header = table.createTHead().insertRow();
  for (const label of ['Market', 'Stake', 'Payout', 'Net']) {
    const heading = node('th', label);
    heading.scope = 'col';
    header.append(heading);
  }
  const body = table.createTBody();
  for (const result of results) {
    const row = body.insertRow();
    const name = row.insertCell();
    name.append(node('strong', result.title), node('small',
      date(result.finished) + (result.unclaimed ? ' · Ready to claim' : ''), 'meta'));
    row.insertCell().textContent = money(result.stake);
    row.insertCell().textContent = money(result.payout);
    const value = row.insertCell();
    value.textContent = signed(result.payout - result.stake);
    if (result.payout < result.stake) value.className = 'negative';
  }
  scroll.append(table);
  content.append(scroll);
}

function renderHeader() {
  document.querySelector('#character').textContent = state?.name || '—';
  document.querySelector('#cash').textContent = Number.isFinite(state?.balance) ? money(state.balance) : '—';
  tabs.forEach(button => {
    button.hidden = button.dataset.tab === 'admin' && !state?.admin;
    if (button.dataset.tab === tab) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
}

function render() {
  renderHeader();
  renderedState = JSON.stringify(state);
  content.replaceChildren();
  if (!state) {
    content.append(node('p', waiting ? 'Loading markets…' : 'Refresh to load markets.', 'meta'));
    return;
  }
  if (tab === 'stats') {
    renderStats();
    return;
  }
  if (state.pending) content.append(node('p', 'Your character has a cash movement awaiting trade manager review.', 'badge'));
  if (tab === 'open') content.append(node('p',
    'Maximum payout per trade · ' + money(state.payoutLimit), 'meta market-limit'));
  if (tab === 'admin') {
    content.append(createForm());
    const reviews = asList(state.reviews);
    if (reviews.length) {
      const reviewSection = node('section', null, 'admin-section');
      const reviewGrid = node('div', null, 'grid');
      reviewGrid.append(...reviews.map(reviewCard));
      reviewSection.append(node('h2', 'Pending cash reviews'), reviewGrid);
      content.append(reviewSection);
    }
    content.append(node('h2', 'Active markets'));
  }
  const markets = asList(state.markets).filter(m => {
    if (tab === 'admin') return m.status === 'open' || m.status === 'closed';
    return tab === 'open' ? m.status === 'open' : m.status !== 'open';
  });
  const grid = node('div', null, 'grid');
  grid.append(...markets.map(card));
  content.append(markets.length ? grid : node('p', tab === 'history' ? 'No results or claims yet.' : 'No markets in this view.', 'meta empty'));
  setWaiting(waiting);
}

tabs.forEach(button => {
  button.onclick = () => {
    tab = button.dataset.tab;
    render();
  };
});
setInterval(() => {
  if (!exchange.hidden) request('view', {}, Boolean(state));
}, 2000);

function resetRequests() {
  clearTimeout(timeout);
  waiting = false;
  polling = false;
  queuedAction = undefined;
}

function syncVisibility() {
  document.body.hidden = exchange.hidden && resultOverlay.hidden;
}

function acknowledgeResult(id) {
  post('resultSeen', { id }).catch(() => {});
}

function showNextResult() {
  if (activeResultId !== null || !resultQueue.length) return;
  const result = resultQueue.shift();
  activeResultId = result.id;
  const profit = result.net > 0;
  const label = profit ? 'Market profit' : 'Market loss';
  const prefix = profit ? '+' : '−';
  const absoluteCents = Math.abs(result.net);
  const format = cents => prefix + resultCurrency.format(cents / 100);
  const amount = document.querySelector('#result-amount');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const duration = reducedMotion ? 0 : 1250;

  resultOverlay.dataset.outcome = profit ? 'profit' : 'loss';
  resultOverlay.classList.remove('leaving');
  document.querySelector('#result-label').textContent = label;
  document.querySelector('#result-market').textContent = result.title;
  document.querySelector('#result-announcement').textContent = label + ', ' + format(absoluteCents) + ', ' + result.title;
  amount.textContent = format(0);
  resultOverlay.hidden = false;
  syncVisibility();
  const started = performance.now();

  function count(now) {
    const progress = duration ? Math.min(1, Math.max(0, (now - started) / duration)) : 1;
    const eased = 1 - (1 - progress) ** 3;
    amount.textContent = format(Math.round(absoluteCents * eased));
    if (progress < 1) {
      requestAnimationFrame(count);
      return;
    }
    recentResults.add(result.id);
    if (recentResults.size > 64) recentResults.delete(recentResults.values().next().value);
    acknowledgeResult(result.id);
    setTimeout(() => {
      resultOverlay.classList.add('leaving');
      setTimeout(() => {
        resultOverlay.hidden = true;
        activeResultId = null;
        syncVisibility();
        showNextResult();
      }, reducedMotion ? 0 : 260);
    }, 2700);
  }
  requestAnimationFrame(count);
}

function receiveResult(result) {
  if (!result || !Number.isSafeInteger(result.id) || !Number.isSafeInteger(result.net) ||
      result.net === 0 || typeof result.title !== 'string') return;
  if (recentResults.has(result.id)) {
    acknowledgeResult(result.id);
    return;
  }
  if (activeResultId === result.id || resultQueue.some(item => item.id === result.id)) return;
  resultQueue.push(result);
  showNextResult();
}

function close() {
  exchange.hidden = true;
  syncVisibility();
  state = null;
  resetRequests();
  post('close').catch(() => {});
}
document.querySelector('#exit').onclick = close;
window.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !exchange.hidden) close();
});
window.addEventListener('message', ({ data }) => {
  if (data.type === 'settlementResult') {
    receiveResult(data.result);
    return;
  }
  if (data.type === 'close') {
    exchange.hidden = true;
    syncVisibility();
    resetRequests();
  }
  if (data.type === 'open') {
    openSession += 1;
    resetRequests();
    draft = {};
    orderDrafts.clear();
    document.querySelector('#bank').textContent = data.bank;
    state = null;
    tab = 'open';
    document.querySelector('#brand').textContent = data.brand;
    exchange.hidden = false;
    document.body.hidden = false;
    request('view');
    render();
  }
  if (data.type === 'response' && !exchange.hidden) {
    const wasPolling = polling;
    const nextAction = queuedAction;
    resetRequests();
    setWaiting(false);
    const changedAccess = state?.admin && !data.admin && 'markets' in data;
    if ('markets' in data) {
      state = data;
      if (tab === 'admin' && !state.admin) tab = 'open';
      const editing = content.contains(document.activeElement);
      const focusField = document.activeElement?.dataset.field;
      if (!wasPolling || changedAccess || ((!editing || tab !== 'admin') && renderedState !== JSON.stringify(state))) {
        const scroll = content.scrollTop;
        render();
        if (wasPolling && focusField) content.querySelector('[data-field="' + focusField + '"]')?.focus({ preventScroll: true });
        content.scrollTop = scroll;
      } else renderHeader();
    }
    if (!wasPolling || data.error) showNotice(data.error || data.notice);
    if (data.notice === 'Market published.') {
      draft = {};
      render();
    }
    if (nextAction) {
      const session = openSession;
      setWaiting(true);
      setTimeout(() => {
        if (exchange.hidden || openSession !== session) return;
        setWaiting(false);
        request(nextAction.action, nextAction.fields);
      }, 400);
    }
  }
});
