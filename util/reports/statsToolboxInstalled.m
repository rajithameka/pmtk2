function p = statsToolboxInstalled()
% Determines if user has http://www.mathworks.com/access/helpdesk/help/toolbox/statistics

p = exist('aoctool','file')>0; % name of obscure toolbox functin
