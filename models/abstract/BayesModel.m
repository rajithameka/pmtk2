classdef BayesModel
 
  
    properties(Abstract = true)
       paramDist; 
    end
    
    methods(Abstract = true)
        
        inferParams;
        logmarglik;
        
        
    end
    
end

