
package SSSPEngine;

import Vector           :: *;
import FIFOF            :: *;
import SpecialFIFOs     :: *;
import GetPut           :: *;
import ClientServer     :: *;
import Connectable      :: *;
import StmtFSM          :: *;
import FShow            :: *;
import BRAMFIFO         :: *;

// ----------------
// BC library imports

import BC_Utils           :: *;
import BC_HW_IFC          :: *;
import BC_Transactors     :: *;

import GaloisTypes::*;
`include "GaloisDefs.bsv"

interface Engine;
    method Action init(BC_AEId fpgaId);
    method ActionValue#(Bit#(64)) result;
    method Bool isDone;
    
    interface Put#(WLEntry) workIn;
    interface Get#(WLEntry) workOut;

    interface Get#(GraphReq) graphReq;
    interface Put#(GraphResp) graphResp;
endinterface

(* synthesize, descending_urgency = "casDone, cas, recvDestNode, getDestNode, getEdges, recvSrcNode, getSrcNode" *)
module mkSSSPEngine(Engine ifc);
    Reg#(BC_AEId) fpgaId <-mkRegU;
    Reg#(Bool) started <- mkReg(False);
    Reg#(Bool) done <- mkRegU;
    
    FIFOF#(WLEntry) workInQ <- mkFIFOF;
    FIFOF#(WLEntry) workOutQ <- mkFIFOF;
    
    FIFOF#(GraphReq) graphReqQ <- mkSizedFIFOF(2);
    FIFOF#(GraphResp) graphRespQ <- mkSizedFIFOF(2);
    Vector#(4, FIFOF#(GraphResp)) graphRespQs <- replicateM(mkSizedFIFOF(2));
    
    FIFOF#(GraphNode) graphNodeQ1 <- mkSizedFIFOF(2);
    FIFOF#(GraphNode) graphNodeQ2 <- mkSizedFIFOF(2);  // # entries = # edgeReq in flight
    
    FIFOF#(NodePayload) newDistQ <- mkSizedFIFOF(2);
    FIFOF#(Tuple3#(NodePayload, NodePayload, GraphNode)) casContextQ1 <- mkSizedFIFOF(2);
    FIFOF#(Tuple3#(NodePayload, NodePayload, GraphNode)) casContextQ2 <- mkSizedFIFOF(2); // # entries = # CAS requests in flight
    
    Reg#(Bit#(48)) numWorkFetched <- mkRegU;
    Reg#(Bit#(48)) numWorkRetired <- mkRegU;
    Reg#(Bit#(48)) numEdgesFetched <- mkRegU;
    Reg#(Bit#(48)) numEdgesRetired <- mkRegU;
    Reg#(Bit#(48)) numEdgesDiscarded <- mkRegU;
    
    function Bool isChannel(GraphResp resp, Channel chan);
        Bool ret = False;
        if(resp matches tagged Node .gnode) begin
            if(gnode.channel == chan) begin
                ret = True;
            end
        end
        return ret;
    endfunction
    
    rule calcDone;
        Bool workEmpty = !workInQ.notEmpty && !workOutQ.notEmpty;
        
        Bool noNodesInFlight = (numWorkFetched == numWorkRetired);
        Bool noEdgesInFlight = (numEdgesFetched == (numEdgesRetired + numEdgesDiscarded));
        
        if(workEmpty && noNodesInFlight && noEdgesInFlight) begin
            done <= True;
        end
        else begin
            done <= False;
        end
    endrule
    
    rule respQ_distribute;
        GraphResp resp = graphRespQ.first;
        graphRespQ.deq();
        
        if(resp matches tagged Node .x) begin
            graphRespQs[x.channel].enq(resp);
            //$display("~~~ SSSPEngine GraphResp Node sending to channel %0d", x.channel);
        end
        else if(resp matches tagged Edge .x) begin
            graphRespQs[x.channel].enq(resp);
            //$display("~~~ SSSPEngine GraphResp Edge sending to channel %0d", x.channel);
        end
        else if(resp matches tagged CAS .x) begin
            graphRespQs[x.channel].enq(resp);
            //$display("~~~ SSSPEngine GraphResp CAS sending to channel %0d", x.channel);
        end
    endrule
    
    rule getSrcNode(started);
        WLEntry pkt = workInQ.first();
        workInQ.deq();
        WLJob job = tpl_2(pkt);
        
        $display("%0d: ~~~ SSSPEngine[%0d]: START getSrcNode priority: %0d, nodeID: %0d", cur_cycle, fpgaId, tpl_1(pkt), job);
        
        graphReqQ.enq(tagged ReadNode{id: job, channel: 0});
        numWorkFetched <= numWorkFetched + 1;
    endrule
    
    rule recvSrcNode;
        if(graphRespQs[0].first matches tagged Node .gnode) begin
            graphRespQs[0].deq();
            GraphNode node = gnode.node;
            graphNodeQ1.enq(node);
            $display("%0d: SSSPEngine[%0d]: graphNode ID %0d payload %0d edgePtr %0d numEdges %0d ", cur_cycle, fpgaId, node.id, node.payload, node.edgePtr, node.numEdges);
        end
        else begin
            $display("ERROR THIS SHOULD NEVER HAPPEN SSSPENGINE 0");
            //$finish(1);
        end
    endrule
    
    Reg#(NodeNumEdges) edgeIdx <- mkReg(0);
    rule getEdges;
        GraphNode node = graphNodeQ1.first();        
        EdgePtr edgeID = node.edgePtr + edgeIdx;
        graphReqQ.enq(tagged ReadEdge{edgeID: edgeID, channel: 1});
        graphNodeQ2.enq(node);
        $display("%0d: ~~~~ SSSPEngine[%0d]: getEdges %0d of %0d", cur_cycle, fpgaId, edgeIdx, node.numEdges-1);
        numEdgesFetched <= numEdgesFetched + 1;
        
        if(edgeIdx == (node.numEdges - 1)) begin
            edgeIdx <= 0;
            graphNodeQ1.deq();
            numWorkRetired <= numWorkRetired + 1;
        end
        else begin
            edgeIdx <= edgeIdx + 1;
        end
    endrule
    
    rule getDestNode;
        if(graphRespQs[1].first matches tagged Edge .gedge) begin
            graphRespQs[1].deq();
            
            GraphNode n = graphNodeQ2.first();
            graphNodeQ2.deq();
            
            GraphEdge e = gedge.gedge;
            NodePayload newDist = n.payload + e.weight;
            newDistQ.enq(newDist);
            $display("%0d: ~~~~ SSSPEngine[%0d]: getDestNode num %0d", cur_cycle, fpgaId, e.dest);
            graphReqQ.enq(tagged ReadNode{id: e.dest, channel: 2});
        end
        else begin
            $display("ERROR THIS SHOULD NEVER HAPPEN SSSPENGINE 1");
            //$finish(1);
        end
    endrule
    
    rule recvDestNode; //(isChannel(graphRespQ.first, 2));
        if(graphRespQs[2].first matches tagged Node .gnode) begin
            graphRespQs[2].deq();
            GraphNode node = gnode.node;
            NodePayload newDist = newDistQ.first();
            newDistQ.deq();
            $display("%0d: ~~~~ SSSPEngine[%0d]: recvDestNode, enqueueing CAS: %0d < %0d?", cur_cycle, fpgaId, newDist, node.payload);
            // tuple3(cmpVal, newVal, destNode)
            casContextQ1.enq(tuple3(node.payload, newDist, node));
        end
        else begin
            $display("ERROR THIS SHOULD NEVER HAPPEN SSSPENGINE 2");
            //$finish(1);
        end
    endrule
    
    rule cas;
        // tuple3(cmpVal, newVal, destNode)
        Tuple3#(NodePayload, NodePayload, GraphNode) cxt = casContextQ1.first();
        casContextQ1.deq();
        $display("%0d: SSSPEngine[%0d]: Attempting CAS...", cur_cycle, fpgaId);
        if(tpl_2(cxt) < tpl_1(cxt)) begin
            $display("   %d < %d, executing CAS!", tpl_2(cxt), tpl_1(cxt));
            graphReqQ.enq(tagged CAS{id: tpl_3(cxt).id, cmpVal: tpl_1(cxt), swapVal: tpl_2(cxt), channel: 3});
            casContextQ2.enq(cxt);
        end
        else begin
            numEdgesDiscarded <= numEdgesDiscarded + 1;
        end
    endrule
    
    rule casDone; //(isChannel(graphRespQ.first, 3));
        if(graphRespQs[3].first matches tagged CAS .cas) begin
            graphRespQs[3].deq();
            
            // tuple3(cmpVal, newVal, destNode)
            Tuple3#(NodePayload, NodePayload, GraphNode) cxt = casContextQ2.first();
            casContextQ2.deq();
            
            if(cas.success) begin
                GraphNode node = tpl_3(cxt);
                WLEntry newWork = tuple2(0, node.id);
                workOutQ.enq(newWork);
                $display("%0d: SSSPEngine[%0d]: CAS Success! Enqueueing new work item: ", cur_cycle, fpgaId, fshow(newWork));
                numEdgesRetired <= numEdgesRetired + 1;
            end
            else begin
                casContextQ1.enq(tuple3(cas.oldVal, tpl_2(cxt), tpl_3(cxt)));
                $display("%0d: SSSPEngine[%0d]: CAS failed, retry...", cur_cycle, fpgaId);
            end
        end
        else begin
            $display("ERROR THIS SHOULD NEVER HAPPEN SSSPENGINE 2");
            //$finish(1);
        end
    endrule
    
    method Action init(BC_AEId fpgaid);
        fpgaId <= fpgaid;
        started <= True;
        done <= False;
        
        numWorkFetched <= 0;
        numWorkRetired <= 0;
        numEdgesFetched <= 0;
        numEdgesRetired <= 0;
        numEdgesDiscarded <= 0;
    endmethod
    
    method ActionValue#(Bit#(64)) result() if(done);
        return 64'hDEAD_BEEF;
    endmethod
    
    method Bool isDone;
        return done;
    endmethod
    
    interface workIn = toPut(workInQ);
    interface workOut = toGet(workOutQ);
    interface graphReq = toGet(graphReqQ);
    interface graphResp = toPut(graphRespQ);
endmodule

endpackage
