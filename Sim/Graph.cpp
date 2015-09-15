
#include <fstream>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include "Graph.h"


Graph::Graph() {

}

Node* Graph::getNode(uint64_t id) {
    return &(nodes[id]);
}

Edge* Graph::getEdge(uint64_t id) {
    return &(edges[id]);
}

void Graph::addNode(Node node) {

}

bool Graph::loadEdgelistFile(const char* file) {

    std::ifstream in(file);
    in >> numNodes >> numEdges;
    
    printf("numNodes: %0llud, numEdges: %0llud\n", numNodes, numEdges);
    //posix_memalign((void**)nodes, 512, numNodes*sizeof(Node));
    //posix_memalign((void**)edges, 512, numEdges*sizeof(Edge));
    nodes = (Node*)malloc(numNodes*sizeof(Node));
    edges = (Edge*)malloc(numEdges*sizeof(Edge));
    printf("Sizeof node: %lud, sizeof edge: %lud\n", sizeof(Node), sizeof(Edge));
    printf("nodes: %0lludB, edges: %0lludB\n", numNodes*sizeof(Node), numEdges*sizeof(Edge));
    
    uint64_t src, dest, weight;
    uint64_t lastNode = -1;
    uint64_t edgeIdx = 0;
    while(in.good()) {
        in >> src >> dest >> weight;
        //std::cout << "---" << src << " " << dest << " " << weight << ", idx: " << edgeIdx << "\n";
        
        // If new node
        if(src != lastNode) {
            assert(src < numNodes);
            nodes[src].id = src;
            nodes[src].payload = -1;
            nodes[src].edgePtr = edgeIdx;
            nodes[src].numEdges = 0;
        }
        
        // Append new edge
        assert(edgeIdx < numEdges);
        if(edgeIdx >= numEdges)
            printf("ERROR: node %lud edgeIdx %lud is not less than numEdges %llud (src %lud, dest %lud, weight %lud)\n", src, edgeIdx, numEdges, src, dest, weight); 
        edges[edgeIdx].dest = dest;
        edges[edgeIdx].weight = weight;
        nodes[src].numEdges += 1;
        
        lastNode = src;
        edgeIdx++;
    }
}