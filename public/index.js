import 'https://unpkg.com/d3@7';
//import * as d3 from 'https://unpkg.com/d3@7?module';

query.value = localStorage.getItem('query'); 
params.value = localStorage.getItem('params'); 

const querystring = new URLSearchParams(window.location.search);
if (querystring.has('params')) {
  params.value = querystring.get('params');
}
if (querystring.has('query')) {
  query.value = querystring.get('query');
  //sqlprompt.submit();
}

document.onreadystatechange = () => {
  if (document.readyState === 'complete') {
  }
};

document.addEventListener('submit', async event => {
  event.preventDefault();
  let data = new FormData(event.target);
  let body = Object.fromEntries(data.entries());

  localStorage.setItem('query', body.query);
  localStorage.setItem('params', body.params);

  body.params = JSON.parse(body.params ? body.params : '[]');

  let nodes = await fetchJSON(event.target.method, event.target.action, body);

  renderHTML(nodes);

  const simulation = d3.forceSimulation()
    .force("charge", d3.forceManyBody())
    .force("collide", d3.forceCollide().radius(30).iterations(30))
    .force("link", d3.forceLink().id(d => JSON.stringify(d.pkey)))
    .force("x", d3.forceX())
    .force("y", d3.forceY())
    .force("center", d3.forceCenter(800 / 2, 600 / 2))
  ;
  const color = d3.scaleOrdinal(d3.schemeCategory10);
  //const color = d3.scaleSequential(d3.interpolateBlues);

  renderGraph(simulation, color, new Set(nodes), new Set([]));
});

async function fetchJSON(method, url, body) {
  let config = {
    method: method.toUpperCase(),
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  };
  let res = await fetch(url, config);
  return await res.json();
}

function renderHTML(nodes) {
  container.append(...nodes.map(node => {
    let article = document.createElement('article');
    article.innerHTML = `
      <h2>${node.rel}</h2>
      <pre>${JSON.stringify(node.record, null, 10)}</pre>
    `;
    article.append(...node.links.map(link => {
      let e = document.createElement('div');
      e.className = 'link';
      e.innerHTML = `
        <a href="/?query=${encodeURIComponent(link.query)}&params=${encodeURIComponent(JSON.stringify(link.params))}">root out</a>
        <form method="POST" action="/query">
          <textarea hidden name="query">
          ${link.query}
          </textarea>
          <textarea hidden name="params">${JSON.stringify(link.params)}</textarea>
          <input type="submit" value="${link.direction}: ${link.fkey}" />
        </form>
      `;
      return e;
    }));
    return article;
  }));
}


function renderGraph(simulation, color, nodes, links) {
  const svg = d3.select('#graph');
  
  const nodeJoin = svg
    .select('#nodes')
    .selectAll('circle')
    .data([...nodes], (d) => JSON.stringify(d.pkey))
    .join(
      (enter) => {
        const circle = enter.append("circle").attr("class", "node")
          .attr("r", 20)
          .style('opacity', 1)
          .attr("fill", d => color(d.rel));
        ;
        circle.append("title").text((d) => JSON.stringify({rel: d.rel, record: d.record}));
        
        circle.call(d3.drag()
          .on("start", event => {
            simulation.stop();
            event.subject.fx = event.subject.x;
            event.subject.fy = event.subject.y;
          })
          .on("drag", event => {
            event.subject.fx = event.x;
            event.subject.fy = event.y;
            simulation.alpha(0).restart();
          })
          .on("end", event => {
            simulation.alpha(1).restart();
          })
        );
        circle.on('click', async event => {
          let newNodes = (await Promise.all(
            event.target.__data__.links.map(
              link => fetchJSON('POST', '/query', link)
            )
          )).flat(1);

          let newLinks = newNodes.reduce((links, newNode) => links.concat(newNode.links.map(link => {
            return {
              source: JSON.stringify(event.target.__data__.pkey),
              target: JSON.stringify(newNode.pkey),
              rel: link.fkey,
            };
          })), []);
          
          renderGraph(simulation, color, nodes.union(new Set(newNodes)), links.union(new Set(newLinks)));
        });
        return circle;
      },
    )
  ;

  const linkJoin = svg
    .select('#edges')
    .selectAll('line')
    .data(links)
    .join("line");

  simulation
    .nodes([...nodes])
    .force('link').links([...links])
  ;


  simulation.on("tick", (e) => {
    linkJoin
      .attr("x1", (d) => d.source.x)
      .attr("y1", (d) => d.source.y)
      .attr("x2", (d) => d.target.x)
      .attr("y2", (d) => d.target.y);

    nodeJoin.attr("cx", (d) => d.x).attr("cy", (d) => d.y);
  });

  simulation.alphaDecay(0.1);
}

