"use strict";

const byId = id => document.getElementById(id);
const set = (id, value) => { byId(id).textContent = value; };
const state = value => value ? "Online" : "Offline";
const setStatus = (id, value, tone) => {
  const element = byId(id);
  element.textContent = value;
  element.className = `${tone}-text`;
};
const svgNamespace = "http://www.w3.org/2000/svg";
const colors = ["#38bdf8", "#22c55e", "#f59e0b", "#a78bfa", "#fb7185", "#2dd4bf", "#f472b6", "#84cc16"];

function svgNode(name, attributes = {}, text = "") {
  const node = document.createElementNS(svgNamespace, name);
  Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
  if (text) node.textContent = text;
  return node;
}

function renderLegend(id, lines) {
  const legend = byId(id);
  legend.replaceChildren();
  lines.forEach(line => {
    const entry = document.createElement("span");
    const swatch = document.createElement("i");
    swatch.style.backgroundColor = line.color;
    entry.append(swatch, document.createTextNode(line.label));
    legend.append(entry);
  });
}

function graphLines(series, metrics) {
  const lines = [];
  (Array.isArray(series) ? series : []).forEach((item, seriesIndex) => {
    metrics.forEach((metric, metricIndex) => {
      const samples = (Array.isArray(item.samples) ? item.samples : []).filter(sample =>
        Number.isFinite(sample.timestamp) && Number.isFinite(sample[metric.key])
      );
      if (!samples.length) return;
      lines.push({
        label: metrics.length === 1 ? item.name : `${item.name} ${metric.label}`,
        color: colors[(seriesIndex * metrics.length + metricIndex) % colors.length],
        samples,
        key: metric.key,
      });
    });
  });
  return lines;
}

function renderSeriesChart(id, captionId, legendId, sourceSeries, metrics, options = {}) {
  const chart = byId(id);
  const lines = graphLines(sourceSeries, metrics);
  chart.replaceChildren();
  renderLegend(legendId, lines);
  if (!lines.length) {
    chart.append(svgNode("text", {x: 32, y: 112, class: "empty"}, "No graph samples available yet."));
    set(captionId, "Waiting for private monitor history.");
    return;
  }

  const width = 900, height = 220, left = 60, right = 20, top = 18, bottom = 34;
  const allSamples = lines.flatMap(line => line.samples.map(sample => ({sample, key: line.key})));
  const firstTime = Math.min(...allSamples.map(item => item.sample.timestamp));
  const lastTime = Math.max(...allSamples.map(item => item.sample.timestamp));
  const timeSpan = Math.max(1, lastTime - firstTime);
  const values = allSamples.map(item => Number(item.sample[item.key]));
  const minimum = options.zeroBased === false ? Math.min(...values) : 0;
  const maximum = Math.max(...values);
  const padding = minimum === maximum ? Math.max(1, maximum * 0.1) : Math.max(0.5, (maximum - minimum) * 0.08);
  const chartMin = options.zeroBased === false ? Math.max(0, minimum - padding) : 0;
  const chartMax = maximum + padding;
  const valueSpan = Math.max(1, chartMax - chartMin);
  const x = sample => left + ((sample.timestamp - firstTime) / timeSpan) * (width - left - right);
  const y = value => top + (1 - ((value - chartMin) / valueSpan)) * (height - top - bottom);
  const format = options.format || (value => Math.round(value).toLocaleString());

  for (let step = 0; step <= 4; step += 1) {
    const gridY = top + (step / 4) * (height - top - bottom);
    const value = chartMax - (step / 4) * valueSpan;
    chart.append(
      svgNode("line", {x1: left, y1: gridY, x2: width - right, y2: gridY, class: "grid-line"}),
      svgNode("text", {x: left - 8, y: gridY + 4, class: "axis-label", "text-anchor": "end"}, format(value)),
    );
  }

  lines.forEach(line => {
    const points = line.samples.map(sample => `${x(sample).toFixed(1)},${y(sample[line.key]).toFixed(1)}`).join(" ");
    chart.append(svgNode("polyline", {points, fill: "none", stroke: line.color, "stroke-width": 2.5, "stroke-linejoin": "round", "stroke-linecap": "round"}));
  });

  const timeFormat = value => new Date(value * 1000).toLocaleTimeString([], {hour: "numeric", minute: "2-digit"});
  chart.append(
    svgNode("text", {x: left, y: height - 8, class: "axis-label"}, timeFormat(firstTime)),
    svgNode("text", {x: width - right, y: height - 8, class: "axis-label", "text-anchor": "end"}, timeFormat(lastTime)),
  );
  const sampleCount = lines.reduce((sum, line) => sum + line.samples.length, 0);
  set(captionId, `${lines.length} series · ${sampleCount.toLocaleString()} samples · 1 hour window`);
}

function renderGraphs(graphs = {}) {
  renderSeriesChart("mtu-chart", "mtu-caption", "mtu-legend", graphs.mtu?.series, [
    {key: "displayMtu", label: "MTU"},
  ], {zeroBased: false, format: value => `${Math.round(value)} B`});
  renderSeriesChart("members-chart", "members-caption", "members-legend", graphs.members?.series, [
    {key: "memberCount", label: "members"},
  ]);
  renderSeriesChart("link-quality-chart", "link-quality-caption", "link-quality-legend", graphs.linkQuality?.series, [
    {key: "avgMs", label: "average"},
  ], {zeroBased: false, format: value => `${value.toFixed(1)} ms`});
  renderSeriesChart("cmap-latency-chart", "cmap-latency-caption", "cmap-latency-legend", graphs.cmapKnet?.series, [
    {key: "latencyAvg", label: "latency"},
  ], {format: value => `${Math.round(value)} µs`});
  const packetSeries = (graphs.cmapKnet?.series || []).map(item => ({
    ...item,
    samples: (item.samples || []).map(sample => ({
      ...sample,
      packets: (sample.txPacketDelta || 0) + (sample.rxPacketDelta || 0) + (sample.errorDelta || 0),
    })),
  }));
  renderSeriesChart("cmap-packets-chart", "cmap-packets-caption", "cmap-packets-legend", packetSeries, [
    {key: "packets", label: "packets/errors"},
  ]);
  renderSeriesChart("test-latency-chart", "test-latency-caption", "test-latency-legend", graphs.tests?.series, [
    {key: "avgMs", label: "average"},
  ], {zeroBased: false, format: value => `${value.toFixed(1)} ms`});
}

function topologyHealth(measurements) {
  if (measurements.some(item => item.status === "offline" || item.quality === "offline")) return "bad";
  const losses = measurements.map(item => item.packetLossPercent).filter(Number.isFinite);
  const latencies = measurements.map(item => item.avgMs).filter(Number.isFinite);
  const jitters = measurements.map(item => item.jitterMs).filter(Number.isFinite);
  if (losses.some(value => value >= 1) || latencies.some(value => value >= 50)) return "bad";
  if (losses.some(value => value > 0) || latencies.some(value => value >= 10) || jitters.some(value => value >= 10)) return "warn";
  return latencies.length ? "good" : "unknown";
}

function renderLinkTopology(series, currentLinks, monitorHostname) {
  const chart = byId("link-topology");
  const edges = new Map();
  const nodes = new Set();
  const addMeasurement = (source, target, measurement) => {
    if (!source || !target || source === target) return;
    nodes.add(source);
    nodes.add(target);
    const pair = [source, target].sort((a, b) => a.localeCompare(b));
    const key = pair.join("\u0000");
    if (!edges.has(key)) edges.set(key, {nodes: pair, directions: new Map()});
    edges.get(key).directions.set(`${source}\u0000${target}`, {source, target, ...measurement});
  };

  (Array.isArray(series) ? series : []).forEach(item => {
    const samples = Array.isArray(item.samples) ? item.samples : [];
    const latest = samples[samples.length - 1];
    if (latest) addMeasurement(item.host, item.peer, latest);
  });
  (Array.isArray(currentLinks) ? currentLinks : []).forEach(link => {
    addMeasurement(monitorHostname, link.hostname, link);
  });

  const description = svgNode("desc", {id: "link-topology-description"}, "Current host-to-host latency measurements.");
  chart.replaceChildren(svgNode("title", {id: "link-topology-title"}, "Corosync link topology"), description);
  const nodeNames = [...nodes].sort((a, b) => a.localeCompare(b));
  if (nodeNames.length < 2) {
    chart.append(svgNode("text", {x: 450, y: 250, class: "empty", "text-anchor": "middle"}, "Waiting for host-to-host measurements…"));
    description.textContent = "No host-to-host latency measurements are available yet.";
    return;
  }
  const measuredEdgeCount = edges.size;
  for (let first = 0; first < nodeNames.length; first += 1) {
    for (let second = first + 1; second < nodeNames.length; second += 1) {
      const pair = [nodeNames[first], nodeNames[second]];
      const key = pair.join("\u0000");
      if (!edges.has(key)) edges.set(key, {nodes: pair, directions: new Map()});
    }
  }

  const centerX = 450, centerY = 250, radiusX = 340, radiusY = 190;
  const positions = new Map(nodeNames.map((name, index) => {
    const angle = -Math.PI / 2 + (index / nodeNames.length) * Math.PI * 2;
    return [name, {x: centerX + Math.cos(angle) * radiusX, y: centerY + Math.sin(angle) * radiusY}];
  }));

  [...edges.values()].forEach((edge, index) => {
    const start = positions.get(edge.nodes[0]);
    const end = positions.get(edge.nodes[1]);
    if (!start || !end) return;
    const measurements = [...edge.directions.values()];
    const health = topologyHealth(measurements);
    const dx = end.x - start.x, dy = end.y - start.y;
    const distance = Math.max(1, Math.hypot(dx, dy));
    const nodeRadius = 48;
    const x1 = start.x + (dx / distance) * nodeRadius;
    const y1 = start.y + (dy / distance) * nodeRadius;
    const x2 = end.x - (dx / distance) * nodeRadius;
    const y2 = end.y - (dy / distance) * nodeRadius;
    if (health === "good") {
      chart.append(svgNode("line", {x1, y1, x2, y2, class: "topology-edge-glow"}));
    }
    const line = svgNode("line", {x1, y1, x2, y2, class: `topology-edge ${health}`});
    const details = measurements.map(item => {
      const latency = Number.isFinite(item.avgMs) ? `${item.avgMs.toFixed(1)} ms` : "unavailable";
      const loss = Number.isFinite(item.packetLossPercent) ? `, ${item.packetLossPercent.toFixed(1)}% loss` : "";
      return `${item.source} → ${item.target}: ${latency}${loss}`;
    }).join("\n");
    line.append(svgNode("title", {}, details));
    chart.append(line);
    const latencies = measurements.map(item => item.avgMs).filter(Number.isFinite);
    if (latencies.length) {
      const label = `${Math.max(...latencies).toFixed(1)} ms`;
      const offset = [-28, -14, 0, 14, 28][index % 5];
      const labelX = (start.x + end.x) / 2 + (-dy / distance) * offset;
      const labelY = (start.y + end.y) / 2 + (dx / distance) * offset;
      chart.append(svgNode("text", {x: labelX, y: labelY, class: "topology-latency", dy: "0.35em"}, label));
    }
  });

  nodeNames.forEach(name => {
    const position = positions.get(name);
    const group = svgNode("g", {"aria-label": `Host ${name}`});
    group.append(
      svgNode("circle", {cx: position.x, cy: position.y, r: 44, class: "topology-node"}),
      svgNode("text", {x: position.x, y: position.y, class: "topology-node-label"}, name),
    );
    chart.append(group);
  });
  description.textContent = `${nodeNames.length} hosts, ${measuredEdgeCount} measured Corosync links, and ${edges.size - measuredEdgeCount} links without a recent measurement. Edge labels show the higher directional average latency.`;
}

function linkTone(value) {
  if (value === "good" || value === "healthy" || value === "joined") return "good";
  if (value === "loss" || value === "jittery" || value === "slow") return "warn";
  return "bad";
}

function metric(value, suffix) {
  return Number.isFinite(value) ? `${value.toFixed(1)}${suffix}` : "—";
}

function renderLinkQualityDetails(links) {
  const body = byId("link-quality-rows");
  body.replaceChildren();
  if (!Array.isArray(links) || !links.length) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 8;
    cell.textContent = "No remote Corosync links measured.";
    row.append(cell);
    body.append(row);
    return;
  }
  links.forEach(link => {
    const row = document.createElement("tr");
    const cells = [
      link.hostname || "unknown peer",
      link.status || "unknown",
      metric(link.packetLossPercent, "%"),
      metric(link.avgMs, " ms"),
      metric(link.maxMs, " ms"),
      metric(link.jitterMs, " ms"),
      link.quality || "unknown",
      Number.isFinite(link.lastUpdatedAt) ? new Date(link.lastUpdatedAt * 1000).toLocaleTimeString() : "—",
    ];
    cells.forEach((value, index) => {
      const cell = document.createElement("td");
      if (index === 1 || index === 6) {
        const tag = document.createElement("span");
        tag.className = `tag ${linkTone(String(value))}`;
        tag.textContent = value;
        cell.append(tag);
      } else {
        cell.textContent = value;
      }
      row.append(cell);
    });
    body.append(row);
  });
}

async function refresh() {
  try {
    const response = await fetch("/snapshot.json", {cache: "no-store"});
    if (!response.ok) throw new Error("Live status is temporarily unavailable.");
    const data = await response.json();
    const healthy = data.overall === "healthy";
    const overall = byId("overall");
    overall.className = `pill ${healthy ? "good" : "warn"}`;
    overall.lastElementChild.textContent = healthy ? "Healthy" : "Needs attention";
    set("updated", `Updated ${new Date(data.generatedAt * 1000).toLocaleString()}`);
    setStatus("corosync", state(data.services.corosync), data.services.corosync ? "good" : "bad");
    setStatus("quorum", data.cluster.quorate ? "Quorate" : "Not quorate", data.cluster.quorate ? "good" : "bad");
    setStatus("members", `${data.cluster.activeMembers} / ${data.cluster.configuredMembers}`, data.cluster.offlineMembers ? "warn" : "good");
    set("members-detail", data.cluster.offlineMembers ? `${data.cluster.offlineMembers} offline` : "All configured nodes active");
    const observedLinks = Object.values(data.links).reduce((sum, value) => sum + value, 0);
    setStatus("links", `${data.links.healthy} / ${observedLinks}`, data.links.degraded || data.links.offline ? "warn" : "good");
    set("links-detail", data.links.degraded || data.links.offline ? `${data.links.degraded} degraded, ${data.links.offline} offline` : "All observed links healthy");
    setStatus("web", `${data.web.online} / ${data.web.total}`, data.web.online === data.web.total ? "good" : "warn");
    setStatus("tailscale", state(data.services.tailscale), data.services.tailscale ? "good" : "bad");
    renderGraphs(data.graphs);
    renderLinkTopology(data.graphs?.linkQuality?.series, data.linkQualityDetails, data.monitorHostname);
    renderLinkQualityDetails(data.linkQualityDetails);
  } catch (error) {
    const overall = byId("overall");
    overall.className = "pill bad";
    overall.lastElementChild.textContent = "Unavailable";
    set("updated", error.message);
  }
}

refresh();
setInterval(refresh, 15000);
